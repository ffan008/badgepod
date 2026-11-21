import SceneKit
import SwiftUI

/// 小豆：吧唧录音库的 3D 形象，一只脖子上挂着耳机的仓鼠。
/// 模型由 Tripo 生成，骨骼和表情贴图由 design/ip/tools/build.py 生成。
/// 它的样子跟着吧唧录音库的状态和录音豆的电量走，点它一下会蹦一蹦。
struct Mascot3DView: NSViewRepresentable {
    var mood: MascotMood
    var power: MascotPower = .unknown
    /// 现在的音量（0…1）。给了它，耳机的灯就跟着声音亮暗，不再按固定节奏呼吸。
    var level: Float?
    /// 不管什么状态都坐在充电仓里（设备页的主视觉用）。
    var inPod = false

    func makeCoordinator() -> MascotScene { MascotScene() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.rendersContinuously = false
        view.isPlaying = true
        view.addGestureRecognizer(NSClickGestureRecognizer(target: context.coordinator, action: #selector(MascotScene.poke)))
        context.coordinator.forcePod = inPod
        context.coordinator.apply(mood, power, animated: false)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.apply(mood, power, animated: true)
        if let level { context.coordinator.setLevel(level) }
    }
}

final class MascotScene: NSObject {
    /// 资源所在的文件夹；默认从 App 包里找，测试时可以指到别处
    static var assetFolder: URL?

    enum Face: String, CaseIterable { case open, happy, sleep, tired }

    /// 一个姿势：各块骨头的目标角度（弧度）
    struct Pose {
        var lean: CGFloat = 0        // 身体前倾
        var headPitch: CGFloat = 0   // 低头为正
        var headRoll: CGFloat = 0    // 歪头
        var ears: CGFloat = 0        // 耳朵往外耷拉为正
        var armL: CGFloat = 0        // 抬手为正
        var armR: CGFloat = 0
        var sway: CGFloat = 0.035    // 待着时左右晃头的幅度
        var swayPeriod: Double = 4.2
        var breath: CGFloat = 0.018  // 呼吸时身体起伏的幅度
        // 下面这几样是「动作」：让每种状态一眼就看得出不一样
        var nod: CGFloat = 0         // 点头的幅度
        var armSwingL: CGFloat = 0.05  // 手上下摆的幅度
        var armSwingR: CGFloat = 0.05  // 和左手同号是一起摆，反号是轮流摆
        var armPeriod: Double = 0      // 手摆一个来回多久；0 表示跟着呼吸
        var yaw: CGFloat = 0         // 整个身子左右转的幅度
        var yawPeriod: Double = 3
        var bob: CGFloat = 0         // 整个身子上下颠的幅度
        var bobPeriod: Double = 1
        var breathPeriod: Double = 3.2
    }

    struct Look {
        var face: Face
        var pose: Pose
        var ring: NSColor            // 耳机光圈的颜色
        var glow: (low: CGFloat, high: CGFloat, period: Double)
        var badge: String?           // 头顶的小图标（SF Symbol）
        var badgeColor: NSColor = .white
    }

    let scene = SCNScene()
    private var bones: [String: SCNNode] = [:]
    private let stage = SCNNode()        // 小豆和充电仓一起放在这里，充电时整体缩小一点
    private let rig = SCNNode()          // 蹦跳作用在这里
    private let pod = SCNNode()          // 充电仓，只在充电时出现
    private let podMaterial = SCNMaterial()
    private let shadow = SCNNode()
    private let badge = SCNNode()
    private let material = SCNMaterial()
    private var faces: [Face: NSImage] = [:]
    private var current: (MascotMood, MascotPower)?
    private var face: Face = .open
    private var blinker: Task<Void, Never>?
    private var rootBase: SCNVector3?
    var forcePod = false

    /// 待命时的灯：暖白，不抢眼
    static let warm = NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.72, alpha: 1)
    static let green = NSColor(calibratedRed: 0.30, green: 0.88, blue: 0.50, alpha: 1)
    static let amber = NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.22, alpha: 1)
    static let red = NSColor(calibratedRed: 1.0, green: 0.32, blue: 0.28, alpha: 1)

    override init() {
        super.init()
        build()
    }

    // MARK: 状态 → 样子

    static func look(_ mood: MascotMood, _ power: MascotPower) -> Look {
        switch mood {
        case .happy:
            return Look(face: .happy, pose: Pose(headPitch: -0.10, ears: -0.10, armL: 1.05, armR: 1.05, sway: 0.05, swayPeriod: 1.2),
                        ring: green, glow: (0.9, 1.6, 0.6), badge: "sparkles", badgeColor: amber)
        case .writing:
            // 埋头写：身子前倾、低头，小幅快速点头，两只手轮流上下敲，整个身子跟着轻轻颠
            return Look(face: .open, pose: Pose(lean: 0.30, headPitch: 0.34, ears: -0.05, armL: 0.75, armR: 0.75, sway: 0.015, swayPeriod: 0.7,
                                                breath: 0.012, nod: 0.09, armSwingL: 0.5, armSwingR: -0.5, armPeriod: 0.34,
                                                yaw: 0.07, yawPeriod: 1.4, bob: 0.028, bobPeriod: 0.34, breathPeriod: 1.6),
                        ring: amber, glow: (0.5, 1.7, 0.34), badge: "pencil.line", badgeColor: amber)
        case .listening:
            // 侧耳听：身子朝一边探过去，耳朵竖起来，慢慢左右转着找声音
            return Look(face: .open, pose: Pose(lean: 0.10, headPitch: -0.04, headRoll: 0.20, ears: -0.22, armL: 0.25, armR: 0.25, sway: 0.03, swayPeriod: 2.6,
                                                nod: 0.03, yaw: 0.16, yawPeriod: 4.5),
                        ring: red, glow: (0.5, 1.7, 1.1), badge: nil)
        case .thinking:
            // 歪头想：头仰着大幅度左右歪，一只手举到下巴边一下一下点，身子左看右看
            return Look(face: .open, pose: Pose(headPitch: -0.14, headRoll: -0.10, ears: 0.05, armL: 1.05, armR: -0.15, sway: 0.22, swayPeriod: 3.2,
                                                armSwingL: 0.16, armSwingR: 0.02, armPeriod: 0.7, yaw: 0.38, yawPeriod: 5.0),
                        ring: amber, glow: (0.4, 1.5, 0.8), badge: "ellipsis", badgeColor: amber)
        case .sleeping:
            return Look(face: .sleep, pose: Pose(lean: 0.05, headPitch: 0.20, headRoll: 0.06, ears: 0.30, armL: -0.25, armR: -0.25, sway: 0.012, swayPeriod: 6, breath: 0.03, breathPeriod: 4.6),
                        ring: NSColor(calibratedWhite: 0.75, alpha: 1), glow: (0.0, 0.0, 4), badge: "zzz", badgeColor: NSColor(calibratedWhite: 0.6, alpha: 1))
        case .idle:
            switch power {
            case .charging(let level):
                // 窝在充电仓里：眯着眼，慢慢呼吸；光圈颜色跟着电量走，充满了就常亮
                let done = level >= 95
                let color = level < 20 ? amber : green
                return Look(face: .happy, pose: Pose(headPitch: 0.06, headRoll: 0.05, ears: 0.12, armL: -0.15, armR: -0.15, sway: 0.015, swayPeriod: 6, breath: 0.032, breathPeriod: 4.2),
                            ring: color, glow: done ? (1.2, 1.2, 4) : (0.25, 1.6, 2.2), badge: done ? "checkmark.circle.fill" : "bolt.fill", badgeColor: done ? green : amber)
            case .low:
                return Look(face: .tired, pose: Pose(lean: 0.06, headPitch: 0.17, headRoll: -0.10, ears: 0.48, armL: -0.3, armR: -0.3, sway: 0.02, swayPeriod: 6.5, breath: 0.026, breathPeriod: 4.8),
                            ring: red, glow: (0.1, 1.5, 1.6), badge: "battery.25percent", badgeColor: red)
            case .full:
                return Look(face: .open, pose: Pose(headPitch: -0.05, ears: -0.12, armL: 0.35, armR: 0.35, sway: 0.05, swayPeriod: 2.8, breath: 0.024, breathPeriod: 2.4),
                            ring: green, glow: (0.9, 1.2, 2.4), badge: nil)
            case .mid, .unknown:
                return Look(face: .open, pose: Pose(), ring: warm, glow: (0.8, 1.1, 3), badge: nil)
            }
        }
    }

    func apply(_ mood: MascotMood, _ power: MascotPower, animated: Bool) {
        if let current, current == (mood, power) { return }
        let previous = current?.0
        current = (mood, power)
        let look = Self.look(mood, power)
        set(look.pose, duration: animated ? 0.5 : 0)
        setFace(look.face)
        setRing(look.ring, glow: look.glow, animated: animated)
        setBadge(look.badge, color: look.badgeColor, drift: mood == .sleeping)
        // 充电仓是小豆的窝：充电的时候在里面，没连上、睡着的时候也在里面
        var inPod = mood == .sleeping || forcePod
        if case .charging = power, mood == .idle { inPod = true }
        setPod(inPod, animated: animated)
        if mood == .happy, animated, previous != .happy { jump(times: 2) }
    }

    /// 让耳机的灯跟着音量走：声音大就亮，安静就暗下去。
    func setLevel(_ level: Float) {
        material.removeAnimation(forKey: "glow")
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        material.setValue(0.35 + 1.6 * CGFloat(min(1, max(0, level))), forKey: "ringGlow")
        SCNTransaction.commit()
    }

    @objc func poke() {
        jump(times: 1)
        guard face == .open else { return }
        show(.happy)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            guard let self else { return }
            show(face)
        }
    }

    // MARK: 搭建

    private static func url(_ name: String, _ ext: String) -> URL? {
        if let assetFolder { return assetFolder.appendingPathComponent("\(name).\(ext)") }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    private func build() {
        scene.lightingEnvironment.contents = Self.gradient([.white, NSColor(calibratedWhite: 0.82, alpha: 1), NSColor(calibratedRed: 0.86, green: 0.82, blue: 0.76, alpha: 1)])
        scene.lightingEnvironment.intensity = 1.5

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 24
        camera.position = SCNVector3(0, 0.62, 3.5)
        camera.eulerAngles = SCNVector3(-0.02, 0, 0)
        scene.rootNode.addChildNode(camera)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.7, 0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 620
        scene.rootNode.addChildNode(fill)

        // 脚下一团软阴影，蹦起来时会变淡
        let plane = SCNPlane(width: 1.1, height: 1.1)
        plane.firstMaterial?.diffuse.contents = Self.blob()
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.writesToDepthBuffer = false
        shadow.geometry = plane
        shadow.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        shadow.position = SCNVector3(0, 0.002, 0)
        shadow.opacity = 0.55
        scene.rootNode.addChildNode(shadow)

        scene.rootNode.addChildNode(stage)
        stage.addChildNode(rig)
        var unused: [String: SCNNode] = [:]
        if let body = Self.loadBody("case", material: podMaterial, bones: &unused) {
            pod.addChildNode(body.skeleton)
            pod.addChildNode(body.mesh)
            podMaterial.lightingModel = .physicallyBased
            podMaterial.diffuse.contents = NSColor(calibratedWhite: 0.88, alpha: 1)
            podMaterial.roughness.contents = 0.35
            podMaterial.metalness.contents = 0.0
            pod.scale = SCNVector3(1.25, 1.25, 1.25)
            pod.opacity = 0
            pod.isHidden = true
            stage.addChildNode(pod)
        }
        for f in Face.allCases {
            if let url = Self.url("face_\(f.rawValue)", "jpg"), let image = NSImage(contentsOf: url) { faces[f] = image }
        }
        if let body = Self.loadBody(material: material, bones: &bones) {
            rig.addChildNode(body.skeleton)
            rig.addChildNode(body.mesh)
        }
        material.lightingModel = .physicallyBased
        material.diffuse.contents = faces[.open]
        material.roughness.contents = 0.62
        material.metalness.contents = 0.0
        if let url = Self.url("normal", "jpg") { material.normal.contents = NSImage(contentsOf: url) }
        if let url = Self.url("ring_mask", "jpg") { material.emission.contents = NSImage(contentsOf: url) }
        // 耳机上的那圈光：贴图里标出位置，颜色和亮度由状态决定
        material.shaderModifiers = [.surface: """
        #pragma arguments
        float3 ringColor;
        float ringGlow;
        #pragma body
        float m = smoothstep(0.35, 0.65, _surface.emission.r);
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb, ringColor * (0.35 + 0.65 * min(ringGlow, 1.0)), m);
        _surface.emission.rgb = ringColor * m * ringGlow * 0.6;
        """]
        material.setValue(NSValue(scnVector3: Self.vector(Self.warm)), forKey: "ringColor")
        material.setValue(1.0, forKey: "ringGlow")

        badge.geometry = SCNPlane(width: 0.2, height: 0.2)
        badge.geometry?.firstMaterial?.lightingModel = .constant
        badge.geometry?.firstMaterial?.isDoubleSided = true
        badge.position = SCNVector3(0.36, 1.02, 0.1)
        badge.opacity = 0
        scene.rootNode.addChildNode(badge)

        blinker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.4...5.5)))
                guard let self else { return }
                guard face == .open else { continue }
                show(.sleep)
                try? await Task.sleep(for: .seconds(0.11))
                show(face)
            }
        }
    }

    deinit { blinker?.cancel() }

    /// 读 hamster.mesh / hamster.json，搭出带蒙皮的身体
    private static func loadBody(_ name: String = "hamster", material: SCNMaterial, bones: inout [String: SCNNode]) -> (mesh: SCNNode, skeleton: SCNNode)? {
        struct Rig: Decodable { struct Bone: Decodable { var name: String; var parent: Int; var pivot: [Float] }; var bones: [Bone]; var colors: Bool? }
        guard let meshURL = url(name, "mesh"), let data = try? Data(contentsOf: meshURL),
              let rigURL = url(name, "json"), let rigData = try? Data(contentsOf: rigURL),
              let rig = try? JSONDecoder().decode(Rig.self, from: rigData), data.count > 8 else { return nil }
        let vertexCount = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })
        let indexCount = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        var offset = 8
        func take(_ bytes: Int) -> Data { defer { offset += bytes }; return data.subdata(in: offset..<offset + bytes) }
        func floats(_ semantic: SCNGeometrySource.Semantic, _ n: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: take(vertexCount * n * 4), semantic: semantic, vectorCount: vertexCount, usesFloatComponents: true,
                              componentsPerVector: n, bytesPerComponent: 4, dataOffset: 0, dataStride: n * 4)
        }
        guard data.count >= 8 + vertexCount * (12 + 12 + 16 + 8 + 8 + 16) + indexCount * 4 else { return nil }
        let position = floats(.vertex, 3), normal = floats(.normal, 3), tangent = floats(.tangent, 4), uv = floats(.texcoord, 2)
        let indices = SCNGeometrySource(data: take(vertexCount * 8), semantic: .boneIndices, vectorCount: vertexCount, usesFloatComponents: false,
                                        componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
        let weights = floats(.boneWeights, 4)
        let element = SCNGeometryElement(data: take(indexCount * 4), primitiveType: .triangles, primitiveCount: indexCount / 3, bytesPerIndex: 4)
        var sources = [position, normal, tangent, uv]
        if rig.colors == true, data.count >= offset + vertexCount * 12 {
            // 没有贴图的道具：颜色直接存在顶点上
            sources = [position, normal, SCNGeometrySource(data: take(vertexCount * 12), semantic: .color, vectorCount: vertexCount, usesFloatComponents: true,
                                                           componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)]
        }
        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [material]

        var nodes: [SCNNode] = []
        var inverses: [NSValue] = []
        for bone in rig.bones {
            let node = SCNNode()
            node.name = bone.name
            let pivot = SCNVector3(CGFloat(bone.pivot[0]), CGFloat(bone.pivot[1]), CGFloat(bone.pivot[2]))
            if bone.parent >= 0 {
                let p = rig.bones[bone.parent].pivot
                node.position = SCNVector3(pivot.x - CGFloat(p[0]), pivot.y - CGFloat(p[1]), pivot.z - CGFloat(p[2]))
                nodes[bone.parent].addChildNode(node)
            } else {
                node.position = pivot
            }
            nodes.append(node)
            bones[bone.name] = node
            inverses.append(NSValue(scnMatrix4: SCNMatrix4MakeTranslation(-pivot.x, -pivot.y, -pivot.z)))
        }
        guard let root = nodes.first else { return nil }
        let mesh = SCNNode(geometry: geometry)
        let skinner = SCNSkinner(baseGeometry: geometry, bones: nodes, boneInverseBindTransforms: inverses, boneWeights: weights, boneIndices: indices)
        skinner.skeleton = root
        mesh.skinner = skinner
        return (mesh, root)
    }

    // MARK: 动作

    /// 先平滑转到新姿势，再在它附近循环小幅度晃动
    private func move(_ name: String, to base: SCNVector3, swing: SCNVector3 = SCNVector3Zero, period: Double = 1, duration: Double) {
        guard let node = bones[name] else { return }
        node.removeAction(forKey: "pose")
        guard duration > 0 else {
            node.eulerAngles = base
            if period > 0, swing.x != 0 || swing.y != 0 || swing.z != 0 { node.runAction(Self.wobble(base, swing, period), forKey: "pose") }
            return
        }
        let go = SCNAction.rotateTo(x: base.x, y: base.y, z: base.z, duration: duration, usesShortestUnitArc: true)
        go.timingMode = .easeInEaseOut
        node.runAction(.sequence([go, Self.wobble(base, swing, period)]), forKey: "pose")
    }

    private static func wobble(_ base: SCNVector3, _ swing: SCNVector3, _ period: Double) -> SCNAction {
        .repeatForever(.customAction(duration: period) { node, t in
            let s = CGFloat(sin(Double(t) / period * 2 * .pi))
            node.eulerAngles = SCNVector3(base.x + swing.x * s, base.y + swing.y * s, base.z + swing.z * s)
        })
    }

    private func set(_ p: Pose, duration: Double) {
        move("body", to: SCNVector3(p.lean, 0, 0), swing: SCNVector3(0, 0, p.sway * 0.3), period: p.swayPeriod, duration: duration)
        move("head", to: SCNVector3(p.headPitch, 0, p.headRoll), swing: SCNVector3(p.sway * 0.4 + p.nod, 0, p.sway), period: p.swayPeriod, duration: duration)
        move("earL", to: SCNVector3(-abs(p.ears) * 0.3, 0, -p.ears), swing: SCNVector3(0, 0, 0.03), period: p.swayPeriod / 2, duration: duration)
        move("earR", to: SCNVector3(-abs(p.ears) * 0.3, 0, p.ears), swing: SCNVector3(0, 0, -0.03), period: p.swayPeriod / 2, duration: duration)
        let armPeriod = p.armPeriod > 0 ? p.armPeriod : p.breathPeriod
        move("armL", to: SCNVector3(0, 0, p.armL), swing: SCNVector3(0, 0, p.armSwingL), period: armPeriod, duration: duration)
        move("armR", to: SCNVector3(0, 0, -p.armR), swing: SCNVector3(0, 0, -p.armSwingR), period: armPeriod, duration: duration)
        // 整个身子的动作：左右转、上下颠
        if let root = bones["root"] {
            if rootBase == nil { rootBase = root.position }
            let base = rootBase ?? SCNVector3Zero
            root.removeAction(forKey: "gesture")
            let yaw = p.yaw, yawPeriod = p.yawPeriod, bob = p.bob, bobPeriod = p.bobPeriod
            if yaw == 0, bob == 0 {
                root.runAction(.group([.rotateTo(x: 0, y: 0, z: 0, duration: max(duration, 0.01)), .move(to: base, duration: max(duration, 0.01))]), forKey: "gesture")
            } else {
                root.runAction(.repeatForever(.customAction(duration: 3600) { node, t in
                    let time = Double(t)
                    let ease = CGFloat(min(1, time / 0.5))          // 刚换状态时慢慢动起来，不突然甩头
                    node.eulerAngles.y = yaw * ease * CGFloat(sin(time / yawPeriod * 2 * .pi))
                    node.position.y = base.y + bob * ease * CGFloat(abs(sin(time / bobPeriod * .pi)))
                }), forKey: "gesture")
            }
        }
        // 呼吸：身体轻轻鼓起来再落回去
        guard let body = bones["body"] else { return }
        body.removeAction(forKey: "breath")
        let amount = p.breath, period = p.breathPeriod
        body.runAction(.repeatForever(.customAction(duration: period) { node, t in
            let s = CGFloat(sin(Double(t) / period * 2 * .pi))
            node.scale = SCNVector3(1 - amount * 0.5 * s, 1 + amount * s, 1 - amount * 0.5 * s)
        }), forKey: "breath")
    }

    private func jump(times: Int) {
        rig.removeAction(forKey: "jump")
        shadow.removeAction(forKey: "jump")
        let up = SCNAction.moveBy(x: 0, y: 0.16, z: 0, duration: 0.16); up.timingMode = .easeOut
        let down = SCNAction.moveBy(x: 0, y: -0.16, z: 0, duration: 0.16); down.timingMode = .easeIn
        let squash = SCNAction.sequence([.scale(to: 0.96, duration: 0.06), .scale(to: 1, duration: 0.10)])
        rig.position = SCNVector3Zero
        rig.runAction(.sequence([.repeat(.sequence([up, down, squash]), count: times), .move(to: SCNVector3Zero, duration: 0)]), forKey: "jump")
        let fade = SCNAction.sequence([.fadeOpacity(to: 0.3, duration: 0.16), .fadeOpacity(to: 0.55, duration: 0.16), .wait(duration: 0.16)])
        shadow.runAction(.repeat(fade, count: times), forKey: "jump")
    }

    /// 充电仓出现或收起：出现时小豆整体缩小、坐进仓里
    private func setPod(_ on: Bool, animated: Bool) {
        guard on != !pod.isHidden else { return }
        stage.removeAllActions(); pod.removeAllActions(); rig.removeAction(forKey: "seat")
        guard animated else {
            stage.scale = on ? SCNVector3(Self.podLayout.stage, Self.podLayout.stage, Self.podLayout.stage) : SCNVector3(1, 1, 1)
            stage.position = on ? Self.podLayout.stageOffset : SCNVector3Zero
            rig.position = on ? Self.podLayout.seat : SCNVector3Zero
            shadow.opacity = on ? 0 : 0.55
            pod.isHidden = !on
            pod.opacity = on ? 1 : 0
            return
        }
        let d = 0.45
        let scale = SCNAction.scale(to: on ? Self.podLayout.stage : 1, duration: d)
        let shift = SCNAction.move(to: on ? Self.podLayout.stageOffset : SCNVector3Zero, duration: d)
        scale.timingMode = .easeInEaseOut; shift.timingMode = .easeInEaseOut
        stage.runAction(.group([scale, shift]))
        let seat = SCNAction.move(to: on ? Self.podLayout.seat : SCNVector3Zero, duration: d)
        seat.timingMode = .easeInEaseOut
        rig.runAction(seat, forKey: "seat")
        shadow.runAction(.fadeOpacity(to: on ? 0 : 0.55, duration: d))
        if on {
            pod.isHidden = false
            pod.runAction(.fadeIn(duration: d))
        } else {
            pod.runAction(.sequence([.fadeOut(duration: d), .hide()]))
        }
    }

    /// 充电仓和小豆的相对摆放（按模型实际尺寸调过）
    static let podLayout = (stage: CGFloat(0.78), stageOffset: SCNVector3(0, 0.03, 0), seat: SCNVector3(0, 0.22, 0.03))

    // MARK: 表情、光圈、小图标

    private func setFace(_ new: Face) {
        face = new
        show(new)
    }

    private func show(_ f: Face) {
        guard let image = faces[f] else { return }
        material.diffuse.contents = image
    }

    func setRing(_ color: NSColor, glow: (low: CGFloat, high: CGFloat, period: Double), animated: Bool) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.4 : 0
        material.setValue(NSValue(scnVector3: Self.vector(color)), forKey: "ringColor")
        SCNTransaction.commit()
        material.removeAnimation(forKey: "glow")
        material.setValue(glow.high, forKey: "ringGlow")
        guard glow.low != glow.high else { return }
        let pulse = CABasicAnimation(keyPath: "ringGlow")
        pulse.fromValue = glow.low
        pulse.toValue = glow.high
        pulse.duration = glow.period / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        material.addAnimation(pulse, forKey: "glow")
    }

    private func setBadge(_ symbol: String?, color: NSColor, drift: Bool) {
        badge.removeAllActions()
        guard let symbol, let image = Self.symbol(symbol, color: color) else {
            badge.runAction(.fadeOut(duration: 0.2))
            return
        }
        badge.geometry?.firstMaterial?.diffuse.contents = image
        badge.position = SCNVector3(0.36, 1.02, 0.1)
        badge.scale = SCNVector3(1, 1, 1)
        if drift {   // Zzz 慢慢往上飘
            let rise = SCNAction.group([.moveBy(x: 0.06, y: 0.14, z: 0, duration: 2.4), .sequence([.fadeOpacity(to: 0.9, duration: 0.6), .wait(duration: 1.0), .fadeOut(duration: 0.8)])])
            badge.runAction(.repeatForever(.sequence([rise, .move(to: SCNVector3(0.36, 1.02, 0.1), duration: 0)])))
        } else {
            let bob = SCNAction.sequence([.moveBy(x: 0, y: 0.03, z: 0, duration: 0.9), .moveBy(x: 0, y: -0.03, z: 0, duration: 0.9)])
            bob.timingMode = .easeInEaseOut
            badge.opacity = 1
            badge.runAction(.repeatForever(bob))
        }
    }

    // MARK: 小工具

    private static func vector(_ c: NSColor) -> SCNVector3 {
        let c = c.usingColorSpace(.sRGB) ?? c
        return SCNVector3(c.redComponent, c.greenComponent, c.blueComponent)
    }

    private static func symbol(_ name: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .semibold).applying(.init(paletteColors: [color]))
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let side = max(base.size.width, base.size.height) + 16
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: NSRect(x: (side - base.size.width) / 2, y: (side - base.size.height) / 2, width: base.size.width, height: base.size.height))
            return true
        }
    }

    private static func gradient(_ colors: [NSColor]) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 256), flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: -90)
            return true
        }
    }

    private static func blob() -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedWhite: 0, alpha: 0.32), NSColor(calibratedWhite: 0, alpha: 0.12), .clear])?
                .draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
            return true
        }
    }
}

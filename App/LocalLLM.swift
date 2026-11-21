import Foundation

/// 吧唧录音库自带的本机分析模型：和转写一样，用 llama-server 跑一个 GGUF 模型，只监听本机。
/// 用它整理纪要时，文字稿不出这台电脑。
actor LocalLLM {
    static let shared = LocalLLM()

    static let fileName = "Qwen3-4B-Q4_K_M.gguf"
    static let displayName = "Qwen3‑4B（本机）"
    static let downloadBase = "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/"
    static let downloadSize = 2_497_280_256.0

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BadgePod/Models/qwen3-4b", isDirectory: true)
    }

    /// 这个文件夹里随便放一个 GGUF 格式的对话模型就行，不要求文件名。
    /// 有多个时优先用默认的那个，否则取最大的。
    nonisolated static var modelURL: URL? {
        let fm = FileManager.default
        let preferred = folder.appendingPathComponent(fileName)
        if fm.fileExists(atPath: preferred.path) { return preferred }
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "gguf" && !$0.lastPathComponent.lowercased().hasPrefix("mmproj") }
            .max { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    nonisolated static var modelLabel: String {
        modelURL.map { $0.deletingPathExtension().lastPathComponent + "（本机）" } ?? displayName
    }

    private var process: Process?
    private var port = 0

    /// 起服务并返回可以直接拿去调用的配置。
    func ensureRunning(serverPath: String) async throws -> LLMConfig {
        if let process, process.isRunning { return config }
        guard let server = QwenASR.locateServer(custom: serverPath) else { throw ASRError.noServer }
        guard let model = Self.modelURL else { throw AnalyzerError.notConfigured }

        port = Int.random(in: 39901...39990)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 外面套一层 sh 盯着吧唧录音库：吧唧录音库退了它也退。--reasoning-budget 0 关掉模型的「先思考再回答」，整理纪要用不上，还慢。
        p.arguments = ["-c", #"parent=$1; shift; "$@" & child=$!; while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done; kill "$child" 2>/dev/null"#,
                       "beanpod-llm", String(ProcessInfo.processInfo.processIdentifier), server.path,
                       "-m", model.path, "--host", "127.0.0.1", "--port", String(port),
                       "-c", "16384", "-np", "1", "--jinja", "--reasoning-budget", "0", "--log-disable"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw ASRError.startFailed(error.localizedDescription) }
        process = p

        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<180 {
            try await Task.sleep(for: .milliseconds(500))
            if !p.isRunning { process = nil; throw ASRError.startFailed(String(localized: "本机分析模型没启动起来，可能是模型文件损坏或内存不够")) }
            if let (_, r) = try? await URLSession.shared.data(from: health), (r as? HTTPURLResponse)?.statusCode == 200 { return config }
        }
        stop()
        throw ASRError.startFailed(String(localized: "本机分析模型等了一分半还没就绪"))
    }

    private var config: LLMConfig {
        LLMConfig(baseURL: "http://127.0.0.1:\(port)/v1", model: Self.modelLabel, key: "", builtIn: true)
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}

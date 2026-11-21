import Foundation

/// 得到 AI 录音卡（GetSeed，型号 GSC10）的蓝牙协议。
///
/// 协议事实来自 Shawn-TKD/getseed-ble-protocol（MIT），作者用实机抓包和固件分析验证过；
/// 这里只按那份文档从零实现，没有拷贝它的代码。出处和许可写在 docs/GETSEED.md 与 NOTICE。
///
/// 和录音豆不同：录音卡的录音是明文的完整 Ogg Opus 文件，不用协商密钥、不用自己封装。
/// 只用「控制」这一条通道：服务 9100，写 9101、通知 9102。
public enum GetSeed {
    public static let service = "00009100-0000-1000-8000-57616C6B697A"
    public static let write = "00009101-0000-1000-8000-57616C6B697A"
    public static let notify = "00009102-0000-1000-8000-57616C6B697A"
    /// 广播里的厂商 ID（小端 4A 54）。广播没有服务 UUID，只能靠名字前缀或厂商 ID 认。
    public static let companyID: UInt16 = 0x544A
    public static let namePrefix = "Get-"

    /// 命令。**故意没有 0x0041**：官方 App 一连上就发它，会永久删除卡里「已经传过」的录音。
    public enum Cmd: UInt16, Sendable {
        case status = 0x0050
        case storage = 0x0042
        case list = 0x0043
        case delete = 0x0044
        case deviceTime = 0x0046
        case mtuReport = 0x0047
        case online = 0x0140
        case download = 0x0145
        case syncTime = 0x0146
        case mtu = 0x0147
        case progress = 0x0150
        case fileSize = 0x0245
        case data = 0x0345
        case done = 0x0445
        case error = 0x0545
    }

    static let magic: [UInt8] = [0xFC, 0xFC, 0xFC, 0xFC]
    /// 下载时设备回「文件不存在」的错误码。
    public static let notFound: UInt8 = 0x5A

    // MARK: 组帧

    /// FC FC FC FC | cmd u16 LE | len u16 LE | body | crc32 LE（zlib 的 CRC‑32，算前面所有字节）。
    public static func frame(_ cmd: UInt16, _ body: [UInt8] = []) -> Data {
        var bytes = magic + le16(Int(cmd)) + le16(body.count) + body
        bytes += le32(crc32(bytes))
        return Data(bytes)
    }

    public static func frame(_ cmd: Cmd, _ body: [UInt8] = []) -> Data { frame(cmd.rawValue, body) }

    /// 对时：14 个 ASCII 字符 YYYYMMDDHHMMSS（本地时间）。
    public static func syncTime(_ now: Date = .now, timeZone: TimeZone = .current) -> Data {
        frame(.syncTime, Array(stamp(now, timeZone: timeZone).utf8))
    }

    /// 要文件列表。body 照官方 App 发的写（01 00 00 00 05 00 00 00），含义推测是「第 1 页、每页 5 条」。
    public static func list(page: UInt32 = 1) -> Data { frame(.list, le32(page) + le32(5)) }

    /// 下载一条：4 个 0 + 文件名。
    public static func download(_ name: String) -> Data { frame(.download, [0, 0, 0, 0] + Array(name.utf8)) }

    /// 删掉一条（永久，不能恢复）：body 就是文件名。
    public static func delete(_ name: String) -> Data { frame(.delete, Array(name.utf8)) }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// zlib 的 CRC‑32（多项式 0xEDB88320，反转，初值和结尾都取反）。
    public static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        ~bytes.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    // MARK: 时间与文件名

    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// 从一串数字里按 年月日时分秒 取出时间，分隔符随意（「2026-10-10-15-06-15.ogg」「2026-10-10 15:06:22」都行）。
    static func parseDate(_ text: String, timeZone: TimeZone) -> Date? {
        var nums = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        // 连写的 YYYYMMDDHHMMSS（设备时间 0x0046 就是这种）
        if nums.count == 1, let digits = text.split(whereSeparator: { !$0.isNumber }).first, digits.count == 14 {
            let d = Array(digits)
            nums = [0..<4, 4..<6, 6..<8, 8..<10, 10..<12, 12..<14].compactMap { Int(String(d[$0])) }
        }
        guard nums.count >= 6, (2000...2100).contains(nums[0]) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: nums[0], month: nums[1], day: nums[2], hour: nums[3], minute: nums[4], second: nums[5]))
    }
}

/// 录音卡发回来的一帧。
public struct GetSeedFrame: Sendable, Equatable {
    public let cmd: UInt16
    public let body: [UInt8]
    public init(cmd: UInt16, body: [UInt8]) { self.cmd = cmd; self.body = body }

    public var command: GetSeed.Cmd? { GetSeed.Cmd(rawValue: cmd) }
    /// body 开头的小端 32 位数（文件大小、偏移都是这种）。
    public var u32: UInt32? { body.count >= 4 ? body.u32(0) : nil }
}

/// 通知可能被切碎，也可能一条里连着几帧：按 FC FC FC FC 找帧头、按长度切。
/// 帧尾的 CRC 不校验（参考实现也不校验），找下一个帧头时自然跳过。
public struct GetSeedReassembler: Sendable {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    public mutating func feed(_ data: Data) -> [GetSeedFrame] {
        buffer.append(contentsOf: data)
        var frames: [GetSeedFrame] = []
        var i = 0
        while true {
            guard let start = Self.findMagic(buffer, from: i) else {
                // 没有帧头：留最后 3 个字节，可能是下一个帧头的前半
                i = max(i, buffer.count - 3)
                break
            }
            i = start
            guard buffer.count - i >= 8 else { break }
            let cmd = UInt16(buffer[i + 4]) | UInt16(buffer[i + 5]) << 8
            let len = Int(buffer[i + 6]) | Int(buffer[i + 7]) << 8
            guard buffer.count - i >= 8 + len else { break }
            frames.append(GetSeedFrame(cmd: cmd, body: Array(buffer[(i + 8)..<(i + 8 + len)])))
            i += 8 + len
            // 帧尾 4 字节 CRC：已经到了就跳过（CRC 的最后一个字节恰好是 FC 时，会和下一个帧头连成一串 FC）
            if buffer.count - i >= 4, !Self.isMagic(buffer, at: i) { i += 4 }
        }
        if i > 0 { buffer.removeFirst(min(i, buffer.count)) }
        // 防止一直收不到帧头时无限长大
        if buffer.count > 64 * 1024 { buffer.removeAll(keepingCapacity: true) }
        return frames
    }

    private static func isMagic(_ b: [UInt8], at j: Int) -> Bool {
        j + 3 < b.count && b[j] == 0xFC && b[j + 1] == 0xFC && b[j + 2] == 0xFC && b[j + 3] == 0xFC
    }

    private static func findMagic(_ b: [UInt8], from: Int) -> Int? {
        var j = from
        while j + 3 < b.count {
            if isMagic(b, at: j) {
                // 连着超过 4 个 FC：前面多出来的是上一帧的尾巴，帧头取最后 4 个（命令号的低字节不会是 FC）
                while j + 4 < b.count, b[j + 4] == 0xFC { j += 1 }
                return j
            }
            j += 1
        }
        return nil
    }
}

/// 卡里的一条录音。列表是一段文字：`序号,文件名,YYYY-MM-DD HH:MM:SS,字节数;` 用分号隔开。
public struct GetSeedFile: Sendable, Equatable, Identifiable {
    public let index: Int
    public let name: String
    /// 文件名里的时间：开始录的时刻。
    public let start: Date?
    /// 第三列的时间：实测是录完的时刻（比文件名晚出录音时长）。
    public let end: Date?
    public let size: Int

    public var id: String { name }

    /// 估计的时长：两个时间相减。拿不到就按约 4.5 KB/秒（实测样本）估。
    public var estimatedDuration: TimeInterval {
        if let start, let end, end > start { return end.timeIntervalSince(start) }
        return Double(size) / 4500
    }

    /// 在吧唧录音库录音库里的编号：开始时刻的秒数（录音豆也是这么编的），拿不到时间就用文件名算一个。
    public var recordingID: UInt32 {
        if let t = start ?? end { return UInt32(max(0, min(Double(UInt32.max), t.timeIntervalSince1970))) }
        return GetSeed.crc32(Array(name.utf8)) | 0x8000_0000
    }

    public static func parseList(_ text: String, timeZone: TimeZone = .current) -> [GetSeedFile] {
        text.split(separator: ";").compactMap { seg in
            let p = seg.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard p.count >= 4, !p[1].isEmpty else { return nil }
            return GetSeedFile(index: Int(p[0]) ?? 0, name: p[1],
                               start: GetSeed.parseDate(p[1], timeZone: timeZone),
                               end: GetSeed.parseDate(p[2], timeZone: timeZone),
                               size: Int(p[3]) ?? 0)
        }
    }
}

/// 一次下载：设备连续推 0x0345（偏移 + 最多 472 字节），不用逐块应答。
/// **偏移是这一块的结束位置**，写入起点 = 偏移 − 本块长度。
public struct GetSeedDownload: Sendable {
    public let name: String
    public var expected = 0
    public private(set) var data = Data()
    public private(set) var received = 0
    public private(set) var chunks = 0
    public var finished = false
    public var notFound = false

    public init(name: String) { self.name = name }

    public mutating func add(_ frame: GetSeedFrame) {
        switch frame.command {
        case .fileSize:
            if let n = frame.u32 { expected = Int(n); if n == 0 { notFound = true } }
        case .data:
            guard frame.body.count > 4, let end = frame.u32 else { return }
            let chunk = frame.body[4...]
            let start = Int(end) - chunk.count
            guard start >= 0, Int(end) < 1 << 30 else { return }
            if Int(end) > data.count { data.append(Data(count: Int(end) - data.count)) }
            data.replaceSubrange(start..<Int(end), with: chunk)
            received += chunk.count
            chunks += 1
        case .done:
            if let n = frame.u32, n > 0, expected == 0 { expected = Int(n) }
            finished = true
        case .error:
            if frame.body.first == GetSeed.notFound { notFound = true }
            finished = true
        default: break
        }
    }

    public var fraction: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
    /// 拿全了：设备说传完了，而且收到的字节数够（重传会让 received 偏大，所以看的是文件长度）。
    public var complete: Bool { expected > 0 && data.count >= expected }
}

// MARK: - 从 Ogg 文件里取出 Opus 包

public extension OggOpus {
    /// 把 Ogg 文件拆回一个个 Opus 包，跳过开头的 OpusHead / OpusTags。
    /// 只认单路流（录音卡和我们自己封装的都是单路）。
    static func packets(fromOgg ogg: Data) -> [Data] {
        let b = [UInt8](ogg)
        var packets: [Data] = []
        var partial: [UInt8] = []
        var i = 0
        while i + 27 <= b.count {
            guard b[i] == 0x4F, b[i + 1] == 0x67, b[i + 2] == 0x67, b[i + 3] == 0x53 else { i += 1; continue }
            let segCount = Int(b[i + 26])
            guard i + 27 + segCount <= b.count else { break }
            let lacing = b[(i + 27)..<(i + 27 + segCount)]
            var p = i + 27 + segCount
            for len in lacing {
                guard p + Int(len) <= b.count else { break }
                partial += b[p..<(p + Int(len))]
                p += Int(len)
                if len < 255 { packets.append(Data(partial)); partial = [] }
            }
            i = p
        }
        return packets.filter { p in
            !(p.starts(with: Array("OpusHead".utf8)) || p.starts(with: Array("OpusTags".utf8)))
        }
    }

    /// 一个 Opus 包在 48 kHz 下有多少个采样（看包头 TOC 字节，RFC 6716 §3.1）。
    static func samplesPerPacket(_ packet: Data) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        let frame: Int
        switch config {
        case 0...11: frame = [480, 960, 1920, 2880][config % 4]          // SILK：10/20/40/60 ms
        case 12...15: frame = [480, 960][config % 2]                     // 混合：10/20 ms
        default: frame = [120, 240, 480, 960][config % 4]                // CELT：2.5/5/10/20 ms
        }
        switch toc & 0x03 {
        case 0: return frame
        case 1, 2: return frame * 2
        default:
            guard packet.count >= 2 else { return nil }
            return frame * Int(packet[packet.startIndex + 1] & 0x3F)
        }
    }
}

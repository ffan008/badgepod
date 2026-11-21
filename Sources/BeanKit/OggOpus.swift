import Foundation

/// 设备给的是裸 Opus 帧（每帧固定 160 字节、20 ms、48 kHz 单声道），没有容器。
/// 这里把它装进标准 Ogg 容器，得到任何播放器都能打开的 .ogg / .opus 文件。
public enum OggOpus {
    public static let frameSize = 160
    public static let samplesPerFrame: UInt64 = 960
    static let preSkip = 312

    public static func frames(fromRaw raw: Data) -> [Data] {
        stride(from: 0, to: raw.count - frameSize + 1, by: frameSize).map {
            raw.subdata(in: (raw.startIndex + $0)..<(raw.startIndex + $0 + frameSize))
        }
    }

    public static func mux(raw: Data) -> Data { mux(packets: frames(fromRaw: raw)) }

    public static func mux(packets: [Data]) -> Data {
        let serial: UInt32 = 0x4245_414E
        var out = Data()
        var seq: UInt32 = 0
        var head = Array("OpusHead".utf8) + [1, 1]
        head += le16(preSkip) + le32(48000) + le16(0) + [0]
        out += page([Data(head)], serial: serial, seq: seq, granule: 0, flags: 0x02); seq += 1
        let vendor = Array("BadgePod".utf8)
        let tags = Array("OpusTags".utf8) + le32(UInt32(vendor.count)) + vendor + le32(0)
        out += page([Data(tags)], serial: serial, seq: seq, granule: 0, flags: 0); seq += 1

        var granule = UInt64(preSkip)
        let perPage = 50
        var i = 0
        while i < packets.count {
            let batch = Array(packets[i..<min(i + perPage, packets.count)])
            granule += samplesPerFrame * UInt64(batch.count)
            i += batch.count
            out += page(batch, serial: serial, seq: seq, granule: granule, flags: i >= packets.count ? 0x04 : 0)
            seq += 1
        }
        return out
    }

    static func page(_ packets: [Data], serial: UInt32, seq: UInt32, granule: UInt64, flags: UInt8) -> Data {
        var segments: [UInt8] = []
        var body: [UInt8] = []
        for p in packets {
            body += p
            var n = p.count
            while n >= 255 { segments.append(255); n -= 255 }
            segments.append(UInt8(n))
        }
        var bytes = Array("OggS".utf8) + [0, flags]
        bytes += (0..<8).map { UInt8((granule >> (8 * UInt64($0))) & 0xFF) }
        bytes += le32(serial) + le32(seq) + [0, 0, 0, 0] + [UInt8(segments.count)] + segments + body
        let crc = crc32(bytes)
        bytes.replaceSubrange(22..<26, with: le32(crc))
        return Data(bytes)
    }

    private static let table: [UInt32] = (0..<256).map { i in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    /// Ogg 用的 CRC‑32：多项式 0x04C11DB7，不反转，初值 0。
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) ^ table[Int((($0 >> 24) ^ UInt32($1)) & 0xFF)] }
    }
}

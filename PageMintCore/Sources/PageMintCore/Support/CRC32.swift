import Foundation

/// ZIP/zlib互換のCRC-32 (多項式 0xEDB88320)。
struct CRC32Hasher {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            for byte in raw {
                state = Self.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
            }
        }
    }

    var value: UInt32 { ~state }

    static func checksum(_ data: Data) -> UInt32 {
        var h = CRC32Hasher()
        h.update(data)
        return h.value
    }
}

extension Data {
    mutating func appendLE16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendLE32(_ v: UInt32) { appendLE16(UInt16(v & 0xFFFF)); appendLE16(UInt16(v >> 16)) }
}

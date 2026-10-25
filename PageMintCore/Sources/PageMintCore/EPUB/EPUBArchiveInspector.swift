import Compression
import Foundation

public struct ArchiveViolation: Sendable, Equatable {
    public let code: String
    public let message: String
}

public struct ArchiveEntryInfo: Sendable, Equatable {
    public let name: String
    public let method: UInt16
    public let flags: UInt16
    public let localExtraLength: Int
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let localOffset: Int
}

public struct ArchiveInspection: Sendable {
    public let entries: [ArchiveEntryInfo]
    public let violations: [ArchiveViolation]
    public var isCompliant: Bool { violations.isEmpty }
}

/// 生成済みEPUB(ZIP)をバイナリ直読みしてOCF条件を検査する (設計書 §9.3 / UT-016)。
/// EPUBCheckとは独立した自前検査であり、EPUBCheckの代替ではない。
public enum EPUBArchiveInspector {
    public static func inspect(url: URL) throws -> ArchiveInspection {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return inspect(data: data)
    }

    public static func inspect(data: Data) -> ArchiveInspection {
        var v: [ArchiveViolation] = []
        func fail(_ code: String, _ msg: String) { v.append(ArchiveViolation(code: code, message: msg)) }
        let b = [UInt8](data)

        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }

        // EOCD探索
        var eocd = -1
        if b.count >= 22 {
            var i = b.count - 22
            let lowest = max(0, b.count - 22 - 65535)
            while i >= lowest {
                if u32(i) == 0x0605_4B50 { eocd = i; break }
                i -= 1
            }
        }
        guard eocd >= 0, let total = u16(eocd + 10), let cdSize = u32(eocd + 12), let cdOffset = u32(eocd + 16),
              let disk = u16(eocd + 4), let cdDisk = u16(eocd + 6)
        else {
            fail("ZIP-EOCD", "End of central directory が見つかりません")
            return ArchiveInspection(entries: [], violations: v)
        }
        if disk != 0 || cdDisk != 0 { fail("ZIP-SPLIT", "分割ZIPは使用できません") }
        guard cdOffset + cdSize <= b.count else {
            fail("ZIP-CD-RANGE", "セントラルディレクトリがファイル範囲外です")
            return ArchiveInspection(entries: [], violations: v)
        }

        var entries: [ArchiveEntryInfo] = []
        var pos = cdOffset
        var seen = Set<String>()
        for index in 0..<total {
            guard u32(pos) == 0x0201_4B50,
                  let flags = u16(pos + 8), let method = u16(pos + 10), let crc = u32(pos + 16),
                  let csize = u32(pos + 20), let usize = u32(pos + 24),
                  let nlen = u16(pos + 28), let elen = u16(pos + 30), let clen = u16(pos + 32),
                  let lofs = u32(pos + 42), pos + 46 + nlen <= b.count
            else {
                fail("ZIP-CD-ENTRY", "セントラルディレクトリのエントリ\(index)が不正です")
                break
            }
            let nameBytes = Array(b[(pos + 46)..<(pos + 46 + nlen)])
            guard let name = String(validating: nameBytes, as: UTF8.self) else {
                fail("ZIP-NAME-UTF8", "エントリ名がUTF-8ではありません (index \(index))")
                pos += 46 + nlen + elen + clen
                continue
            }
            pos += 46 + nlen + elen + clen

            if !seen.insert(name.lowercased()).inserted { fail("ZIP-DUPLICATE", "重複エントリ: \(name)") }
            if flags & 0x1 != 0 { fail("ZIP-ENCRYPTED", "暗号化エントリ: \(name)") }
            if method != 0 && method != 8 { fail("ZIP-METHOD", "未対応の圧縮方式 \(method): \(name)") }
            if (try? EPUBArchiveWriter.validateName(name)) == nil { fail("ZIP-NAME", "不正なエントリ名: \(name)") }
            if name.hasPrefix("__MACOSX") || name.hasSuffix(".DS_Store") || name.split(separator: "/").last?.hasPrefix("._") == true {
                fail("ZIP-JUNK", "Finder由来の不要ファイル: \(name)")
            }

            // ローカルヘッダとの整合
            guard u32(lofs) == 0x0403_4B50, let lflags = u16(lofs + 6), let lmethod = u16(lofs + 8),
                  let lcrc = u32(lofs + 14), let lc = u32(lofs + 18), let lu = u32(lofs + 22),
                  let lnlen = u16(lofs + 26), let lelen = u16(lofs + 28)
            else {
                fail("ZIP-LOCAL", "ローカルヘッダが不正: \(name)")
                continue
            }
            let dataStart = lofs + 30 + lnlen + lelen
            if lmethod != method || lflags != flags || lcrc != crc || lc != csize || lu != usize {
                fail("ZIP-LOCAL-MISMATCH", "ローカルヘッダとセントラルディレクトリが不一致: \(name)")
            }
            if lflags & 0x8 != 0 { fail("ZIP-DATA-DESCRIPTOR", "データディスクリプタは使用しない: \(name)") }
            if Array(b[(lofs + 30)..<min(b.count, lofs + 30 + lnlen)]) != nameBytes {
                fail("ZIP-LOCAL-NAME", "ローカルヘッダ名が不一致: \(name)")
            }

            guard dataStart + csize <= b.count else {
                fail("ZIP-DATA-RANGE", "データがファイル範囲外: \(name)")
                continue
            }
            let payload = Data(b[dataStart..<(dataStart + csize)])
            var plain: Data? = payload
            if method == 8 { plain = inflate(payload, expected: usize) }
            if let plain, plain.count == usize {
                if CRC32Hasher.checksum(plain) != UInt32(truncatingIfNeeded: crc) {
                    fail("ZIP-CRC", "CRC不一致: \(name)")
                }
                if name == "mimetype", plain != EPUBArchiveWriter.mimetypeContent {
                    fail("OCF-MIMETYPE-CONTENT", "mimetypeの内容が `application/epub+zip` (改行・BOMなし) と一致しません")
                }
            } else {
                fail("ZIP-INFLATE", "展開できない/サイズ不一致: \(name)")
            }

            entries.append(ArchiveEntryInfo(
                name: name, method: UInt16(method), flags: UInt16(flags), localExtraLength: lelen,
                compressedSize: csize, uncompressedSize: usize, localOffset: lofs))
        }

        // mimetype の物理条件
        if let first = entries.min(by: { $0.localOffset < $1.localOffset }) {
            if first.localOffset != 0 || first.name != "mimetype" {
                fail("OCF-MIMETYPE-FIRST", "mimetype がZIP物理先頭ではありません (先頭: \(first.name))")
            }
        } else {
            fail("ZIP-EMPTY", "エントリがありません")
        }
        if let m = entries.first(where: { $0.name == "mimetype" }) {
            if m.method != 0 { fail("OCF-MIMETYPE-METHOD", "mimetype は Stored(0) でなければなりません (実際: \(m.method))") }
            if m.localExtraLength != 0 { fail("OCF-MIMETYPE-EXTRA", "mimetype のローカルヘッダに extra field があります") }
            if m.flags & 0x1 != 0 { fail("OCF-MIMETYPE-ENCRYPTED", "mimetype が暗号化されています") }
        } else {
            fail("OCF-MIMETYPE-MISSING", "mimetype エントリがありません")
        }
        if entries.count != total { fail("ZIP-COUNT", "宣言エントリ数 \(total) と解析数 \(entries.count) が不一致") }

        return ArchiveInspection(entries: entries, violations: v)
    }

    private static func inflate(_ data: Data, expected: Int) -> Data? {
        if expected == 0 { return data.isEmpty ? Data() : nil }
        var out = Data(count: expected)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return n == expected ? out : nil
    }
}

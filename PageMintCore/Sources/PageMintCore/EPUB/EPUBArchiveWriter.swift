import Compression
import Foundation

public enum ArchiveError: Error, Equatable, Sendable {
    case duplicateEntry(String)
    case invalidEntryName(String)
    case entryTooLarge(String)
    case tooManyEntries
    case sourceChangedDuringRead(String)
    case closed
    case io(String)
}

public enum ZipCompression: Sendable {
    case stored
    case deflate
}

/// EPUB OCF向けの最小ZIPライター。
///
/// 不変条件 (設計書 §9.3):
/// - `mimetype` は必ず物理先頭エントリ。method=0 (Stored)、extra field なし、内容は改行なしの `application/epub+zip`。
/// - 圧縮方式は Stored / Deflate のみ。暗号化・分割・ZIP64・データディスクリプタは使わない。
/// - エントリ名は検証済みUTF-8 (パストラバーサル・重複・大文字小文字違いの重複を拒否)。
///
/// 画像のような圧縮済みデータは Stored でファイルからストリーミングする。
public final class EPUBArchiveWriter {
    public static let mimetypeContent = Data("application/epub+zip".utf8)

    private struct CentralRecord {
        let name: Data
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localOffset: UInt32
    }

    private let destination: URL
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var records: [CentralRecord] = []
    private var seenNames = Set<String>()
    private let dosTime: UInt16
    private let dosDate: UInt16

    /// 既存ファイルは上書きする。呼び出し側がステージング領域のURLを渡すこと。
    public init(destination: URL, timestamp: Date = Date()) throws {
        self.destination = destination
        let dos = Self.dosDateTime(timestamp)
        dosDate = dos.0
        dosTime = dos.1
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            throw ArchiveError.io("cannot open \(destination.lastPathComponent): \(error.localizedDescription)")
        }
        try writeEntry(
            name: "mimetype", data: Self.mimetypeContent, method: .stored,
            versionNeeded: 10, markUTF8: false)
    }

    deinit { try? handle?.close() }

    // MARK: Public API

    public func addEntry(path: String, data: Data, compression: ZipCompression) throws {
        try Self.validateName(path)
        try writeEntry(name: path, data: data, method: compression, versionNeeded: 20, markUTF8: true)
    }

    /// ファイルをStoredでストリーミング追加する。CRC算出と書き込みで2回読む。
    public func addStoredFile(path: String, from source: URL) throws {
        try Self.validateName(path)
        let reader: FileHandle
        do { reader = try FileHandle(forReadingFrom: source) } catch {
            throw ArchiveError.io("cannot read \(source.lastPathComponent)")
        }
        defer { try? reader.close() }

        var hasher = CRC32Hasher()
        var size: UInt64 = 0
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(chunk)
            size += UInt64(chunk.count)
        }
        guard size <= UInt64(UInt32.max) else { throw ArchiveError.entryTooLarge(path) }
        let crc = hasher.value
        try reader.seek(toOffset: 0)

        let local = try beginEntry(
            name: path, flags: 0x0800, method: 0, crc: crc,
            compressedSize: UInt32(size), uncompressedSize: UInt32(size), versionNeeded: 20)
        var copied: UInt64 = 0
        var verify = CRC32Hasher()
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            verify.update(chunk)
            copied += UInt64(chunk.count)
            try write(chunk)
        }
        // 読取り中に元ファイルが変化した場合は不整合なアーカイブを残さない。
        guard copied == size, verify.value == crc else {
            throw ArchiveError.sourceChangedDuringRead(path)
        }
        records.append(local)
    }

    /// セントラルディレクトリとEOCDを書いて閉じる。
    public func finish() throws {
        guard handle != nil else { throw ArchiveError.closed }
        guard records.count <= Int(UInt16.max) else { throw ArchiveError.tooManyEntries }
        let cdStart = offset
        var cd = Data()
        for r in records {
            cd.appendLE32(0x0201_4B50)
            cd.appendLE16(20)            // version made by
            cd.appendLE16(r.method == 0 && r.name == Data("mimetype".utf8) ? 10 : 20)
            cd.appendLE16(r.flags)
            cd.appendLE16(r.method)
            cd.appendLE16(dosTime)
            cd.appendLE16(dosDate)
            cd.appendLE32(r.crc)
            cd.appendLE32(r.compressedSize)
            cd.appendLE32(r.uncompressedSize)
            cd.appendLE16(UInt16(r.name.count))
            cd.appendLE16(0)             // extra
            cd.appendLE16(0)             // comment
            cd.appendLE16(0)             // disk start
            cd.appendLE16(0)             // internal attrs
            cd.appendLE32(0)             // external attrs
            cd.appendLE32(r.localOffset)
            cd.append(r.name)
        }
        guard cdStart + UInt64(cd.count) <= UInt64(UInt32.max) else {
            throw ArchiveError.entryTooLarge("central directory offset")
        }
        try write(cd)
        var eocd = Data()
        eocd.appendLE32(0x0605_4B50)
        eocd.appendLE16(0)
        eocd.appendLE16(0)
        eocd.appendLE16(UInt16(records.count))
        eocd.appendLE16(UInt16(records.count))
        eocd.appendLE32(UInt32(cd.count))
        eocd.appendLE32(UInt32(cdStart))
        eocd.appendLE16(0)
        try write(eocd)
        try handle?.synchronize()
        try handle?.close()
        handle = nil
    }

    /// 失敗・キャンセル時: 書きかけのアーカイブを閉じて削除する。
    public func abort() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: destination)
    }

    // MARK: Internals

    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= Int(UInt16.max),
              !name.hasPrefix("/"), !name.hasSuffix("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw ArchiveError.invalidEntryName(name) }
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." {
                throw ArchiveError.invalidEntryName(name)
            }
        }
    }

    private func writeEntry(
        name: String, data: Data, method requested: ZipCompression,
        versionNeeded: UInt16, markUTF8: Bool
    ) throws {
        guard data.count <= Int(UInt32.max) else { throw ArchiveError.entryTooLarge(name) }

        var payload = data
        var method: UInt16 = 0
        if requested == .deflate, let deflated = Self.rawDeflate(data), deflated.count < data.count {
            payload = deflated
            method = 8
        }
        let flags: UInt16 = (markUTF8 && !name.utf8.allSatisfy { $0 < 0x80 }) ? 0x0800 : 0
        let record = try beginEntry(
            name: name, flags: flags, method: method, crc: CRC32Hasher.checksum(data),
            compressedSize: UInt32(payload.count), uncompressedSize: UInt32(data.count),
            versionNeeded: versionNeeded)
        try write(payload)
        records.append(record)
    }

    /// ローカルヘッダを書き、セントラルディレクトリ用レコードを返す。
    private func beginEntry(
        name: String, flags: UInt16, method: UInt16, crc: UInt32,
        compressedSize: UInt32, uncompressedSize: UInt32, versionNeeded: UInt16
    ) throws -> CentralRecord {
        let key = name.lowercased()
        guard !seenNames.contains(key) else { throw ArchiveError.duplicateEntry(name) }
        guard offset <= UInt64(UInt32.max) else { throw ArchiveError.entryTooLarge(name) }
        seenNames.insert(key)

        let nameData = Data(name.utf8)
        let localOffset = UInt32(offset)
        var h = Data()
        h.appendLE32(0x0403_4B50)
        h.appendLE16(versionNeeded)
        h.appendLE16(flags)
        h.appendLE16(method)
        h.appendLE16(dosTime)
        h.appendLE16(dosDate)
        h.appendLE32(crc)
        h.appendLE32(compressedSize)
        h.appendLE32(uncompressedSize)
        h.appendLE16(UInt16(nameData.count))
        h.appendLE16(0)  // extra field length: 常に0
        h.append(nameData)
        try write(h)
        return CentralRecord(
            name: nameData, flags: flags, method: method, crc: crc,
            compressedSize: compressedSize, uncompressedSize: uncompressedSize, localOffset: localOffset)
    }

    private func write(_ data: Data) throws {
        guard let handle else { throw ArchiveError.closed }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw ArchiveError.io("write failed: \(error.localizedDescription)")
        }
        offset += UInt64(data.count)
    }

    /// ZIP method 8 用の生DEFLATE (RFC1951)。Apple の COMPRESSION_ZLIB は zlibヘッダなしの生DEFLATE。
    static func rawDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(written...)
        return out
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        let d = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        let t = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | ((c.second ?? 0) / 2))
        return (d, t)
    }
}

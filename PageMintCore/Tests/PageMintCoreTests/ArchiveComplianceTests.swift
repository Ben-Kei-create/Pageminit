import Foundation
import Testing
@testable import PageMintCore

@Suite("ZIP/OCF archive compliance")
struct ArchiveComplianceTests {
    @Test func crc32KnownVector() {
        #expect(CRC32Hasher.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    // UT-016
    @Test func mimetypeIsFirstStoredWithoutExtra() throws {
        let fx = try TestSupport.makeFixture(pages: 2)
        let out = fx.dir.appendingPathComponent("a.epub")
        try EPUBBuilder().build(
            EPUBBookInput(metadata: BookMetadata(title: "T", creator: "C"), cover: nil, pages: fx.pages), to: out)

        // 生バイトを直接確認 (インスペクタ実装に依存しない)
        let b = [UInt8](try Data(contentsOf: out).prefix(64))
        #expect(Array(b[0..<4]) == [0x50, 0x4B, 0x03, 0x04])          // local header signature
        #expect(b[8] == 0 && b[9] == 0)                                // method = 0 (Stored)
        #expect(b[6] & 0x01 == 0 && b[6] & 0x08 == 0)                  // not encrypted, no data descriptor
        #expect(b[28] == 0 && b[29] == 0)                              // extra field length = 0
        #expect(b[26] == 8 && b[27] == 0)                              // name length = 8
        #expect(String(decoding: b[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: b[38..<58], as: UTF8.self) == "application/epub+zip")
        #expect(b[58] == 0x50)                                         // 直後は次のPK (改行・余分なバイトなし)

        let inspection = try EPUBArchiveInspector.inspect(url: out)
        #expect(inspection.violations.isEmpty, "\(inspection.violations)")
        #expect(inspection.entries.first?.name == "mimetype")
    }

    @Test func independentUnzipAcceptsArchive() throws {
        let fx = try TestSupport.makeFixture(pages: 3, cover: true)
        let out = fx.dir.appendingPathComponent("a.epub")
        try EPUBBuilder().build(
            EPUBBookInput(metadata: BookMetadata(title: "T"), cover: fx.cover, pages: fx.pages), to: out)
        #expect(try TestSupport.run("/usr/bin/unzip", ["-tq", out.path]).status == 0)
        let list = try TestSupport.unzipList(out)
        #expect(list.first == "mimetype")
        // 画像は元バイトのまま格納 (再エンコードしない)
        let stored = try TestSupport.unzipEntry(out, "OEBPS/images/page-0001.png")
        #expect(stored == (try Data(contentsOf: fx.pages[0].fileURL)))
    }

    @Test func deflatedEntriesRoundTripAndPassInspection() throws {
        let dir = try TestSupport.makeTempDir()
        let out = dir.appendingPathComponent("z.epub")
        let w = try EPUBArchiveWriter(destination: out)
        let big = Data(String(repeating: "<p>hello 日本語</p>\n", count: 5000).utf8)
        try w.addEntry(path: "OEBPS/big.xhtml", data: big, compression: .deflate)
        try w.addEntry(path: "OEBPS/empty.txt", data: Data(), compression: .deflate)
        try w.finish()
        let ins = try EPUBArchiveInspector.inspect(url: out)
        #expect(ins.violations.isEmpty, "\(ins.violations)")
        #expect(ins.entries.first(where: { $0.name == "OEBPS/big.xhtml" })?.method == 8)
        #expect(ins.entries.first(where: { $0.name == "OEBPS/empty.txt" })?.method == 0)
        #expect(try TestSupport.unzipEntry(out, "OEBPS/big.xhtml") == big)
    }

    @Test(arguments: ["../evil", "/abs", "a/../b", "a//b", "dir/", "", "a\\b", "ctl\u{01}x", "./x"])
    func writerRejectsUnsafeNames(_ name: String) throws {
        let dir = try TestSupport.makeTempDir()
        let w = try EPUBArchiveWriter(destination: dir.appendingPathComponent("x.epub"))
        #expect(throws: ArchiveError.self) { try w.addEntry(path: name, data: Data("x".utf8), compression: .stored) }
    }

    @Test func writerRejectsDuplicatesIncludingCaseVariants() throws {
        let dir = try TestSupport.makeTempDir()
        let w = try EPUBArchiveWriter(destination: dir.appendingPathComponent("x.epub"))
        try w.addEntry(path: "OEBPS/a.txt", data: Data("x".utf8), compression: .stored)
        #expect(throws: ArchiveError.duplicateEntry("OEBPS/a.txt")) {
            try w.addEntry(path: "OEBPS/a.txt", data: Data("y".utf8), compression: .stored)
        }
        #expect(throws: ArchiveError.duplicateEntry("OEBPS/A.TXT")) {
            try w.addEntry(path: "OEBPS/A.TXT", data: Data("y".utf8), compression: .stored)
        }
        #expect(throws: ArchiveError.duplicateEntry("mimetype")) {
            try w.addEntry(path: "mimetype", data: Data("y".utf8), compression: .stored)
        }
    }

    // ---- インスペクタの否定テスト (壊れたZIPを確実に検出するか) ----

    private func goodEPUBBytes() throws -> Data {
        let fx = try TestSupport.makeFixture(pages: 1)
        let out = fx.dir.appendingPathComponent("g.epub")
        try EPUBBuilder().build(EPUBBookInput(metadata: BookMetadata(title: "T"), cover: nil, pages: fx.pages), to: out)
        return try Data(contentsOf: out)
    }

    @Test func inspectorFlagsCompressedMimetype() throws {
        var d = try goodEPUBBytes()
        d[8] = 8  // local header method を Deflate に改竄
        let codes = Set(EPUBArchiveInspector.inspect(data: d).violations.map(\.code))
        #expect(codes.contains("OCF-MIMETYPE-METHOD") || codes.contains("ZIP-LOCAL-MISMATCH"))
        #expect(!codes.isEmpty)
    }

    @Test func inspectorFlagsMimetypeContentTamper() throws {
        var d = try goodEPUBBytes()
        d[38] = 0x58  // 'a' -> 'X'
        let codes = Set(EPUBArchiveInspector.inspect(data: d).violations.map(\.code))
        #expect(codes.contains("ZIP-CRC"))
    }

    @Test func inspectorFlagsCorruptedImageCRC() throws {
        var d = try goodEPUBBytes()
        let marker = Data([0x89, 0x50, 0x4E, 0x47])  // PNG signature
        let r = try #require(d.range(of: marker))
        d[r.lowerBound + 40] ^= 0xFF
        #expect(EPUBArchiveInspector.inspect(data: d).violations.contains { $0.code == "ZIP-CRC" })
    }

    @Test func inspectorRejectsNonZip() {
        #expect(EPUBArchiveInspector.inspect(data: Data("not a zip".utf8)).violations.contains { $0.code == "ZIP-EOCD" })
    }

    @Test func inspectorFlagsMimetypeNotFirst() throws {
        // mimetype を後ろに置いた(ライターでは作れない)ZIPを手組みして検出できることを確認
        var zip = Data()
        var records: [(Data, UInt32, Data, UInt32)] = []  // name, crc, payload, offset
        func local(_ name: String, _ payload: Data) {
            let off = UInt32(zip.count)
            let nameData = Data(name.utf8)
            let crc = CRC32Hasher.checksum(payload)
            zip.appendLE32(0x0403_4B50); zip.appendLE16(10); zip.appendLE16(0); zip.appendLE16(0)
            zip.appendLE16(0); zip.appendLE16(0x21); zip.appendLE32(crc)
            zip.appendLE32(UInt32(payload.count)); zip.appendLE32(UInt32(payload.count))
            zip.appendLE16(UInt16(nameData.count)); zip.appendLE16(0); zip.append(nameData); zip.append(payload)
            records.append((nameData, crc, payload, off))
        }
        local("META-INF/container.xml", Data("<x/>".utf8))
        local("mimetype", Data("application/epub+zip".utf8))
        let cdStart = zip.count
        for r in records {
            zip.appendLE32(0x0201_4B50); zip.appendLE16(20); zip.appendLE16(10); zip.appendLE16(0); zip.appendLE16(0)
            zip.appendLE16(0); zip.appendLE16(0x21); zip.appendLE32(r.1)
            zip.appendLE32(UInt32(r.2.count)); zip.appendLE32(UInt32(r.2.count))
            zip.appendLE16(UInt16(r.0.count)); zip.appendLE16(0); zip.appendLE16(0); zip.appendLE16(0)
            zip.appendLE16(0); zip.appendLE32(0); zip.appendLE32(r.3); zip.append(r.0)
        }
        let cdSize = zip.count - cdStart
        zip.appendLE32(0x0605_4B50); zip.appendLE16(0); zip.appendLE16(0)
        zip.appendLE16(UInt16(records.count)); zip.appendLE16(UInt16(records.count))
        zip.appendLE32(UInt32(cdSize)); zip.appendLE32(UInt32(cdStart)); zip.appendLE16(0)
        #expect(EPUBArchiveInspector.inspect(data: zip).violations.contains { $0.code == "OCF-MIMETYPE-FIRST" })
    }
}

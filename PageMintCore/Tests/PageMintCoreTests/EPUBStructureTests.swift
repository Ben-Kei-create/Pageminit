import Foundation
import Testing
@testable import PageMintCore

@Suite("EPUB structure")
struct EPUBStructureTests {
    private func build(
        _ meta: BookMetadata, pages: Int = 3, cover: Bool = false, mixed: Bool = false, alt: String? = nil
    ) throws -> (epub: URL, result: EPUBBuildResult, fx: TestSupport.Fixture) {
        let fx = try TestSupport.makeFixture(pages: pages, cover: cover, mixedRatios: mixed, alt: alt)
        let out = fx.dir.appendingPathComponent("book.epub")
        let r = try EPUBBuilder().build(
            EPUBBookInput(metadata: meta, cover: fx.cover, pages: fx.pages, modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            to: out)
        return (out, r, fx)
    }

    private func xml(_ epub: URL, _ path: String) throws -> XMLDocument {
        try XMLDocument(data: try TestSupport.unzipEntry(epub, path), options: [])
    }

    private func strings(_ doc: XMLDocument, _ xpath: String) throws -> [String] {
        try doc.nodes(forXPath: xpath).compactMap(\.stringValue)
    }

    @Test func allXMLPartsAreWellFormed() throws {
        let (epub, _, _) = try build(BookMetadata(title: "T", subtitle: "S", creator: "C"), cover: true)
        for path in try TestSupport.unzipList(epub) where path.hasSuffix(".xhtml") || path.hasSuffix(".opf") || path.hasSuffix(".xml") {
            _ = try xml(epub, path)
        }
    }

    // UT-009
    @Test func metadataSpecialCharactersAreEscaped() throws {
        let nasty = "A & B <C> \"D\" 'E' 😀 ｶﾞ 𠮷 長音ー"
        let meta = BookMetadata(
            title: nasty, subtitle: "<sub>&", creator: "著者 & \"共著\"", publisher: "出版 <社>",
            description: "line1\nline2 & <b>", readingDirection: .ltr)
        let (epub, _, _) = try build(meta)
        let opf = try xml(epub, "OEBPS/package.opf")
        #expect(try strings(opf, "//*[local-name()='title'][@id='title']") == [nasty])
        #expect(try strings(opf, "//*[local-name()='title'][@id='subtitle']") == ["<sub>&"])
        #expect(try strings(opf, "//*[local-name()='creator']") == ["著者 & \"共著\""])
        #expect(try strings(opf, "//*[local-name()='publisher']") == ["出版 <社>"])
        #expect(try strings(opf, "//*[local-name()='description']") == ["line1\nline2 & <b>"])
        // 生バイトにも未エスケープの "<C>" が出ていない
        let raw = String(decoding: try TestSupport.unzipEntry(epub, "OEBPS/package.opf"), as: UTF8.self)
        #expect(!raw.contains("<C>"))
    }

    @Test func invalidXMLCharactersAreRejectedNotSilentlyDropped() {
        #expect(throws: XMLSerializationError.invalidCharacter(0x1)) { try EPUBXMLSerializer.escape("a\u{01}b") }
        #expect(throws: XMLSerializationError.invalidCharacter(0xFFFE)) { try EPUBXMLSerializer.escape("a\u{FFFE}") }
        #expect((try? EPUBXMLSerializer.escape("tab\tnl\n")) == "tab\tnl\n")
    }

    // UT-010
    @Test func languageAndIdentifier() throws {
        #expect(throws: EPUBBuildError.self) { _ = try build(BookMetadata(title: "T", languageTag: "japanese!!")) }
        #expect(throws: EPUBBuildError.self) { _ = try build(BookMetadata(title: "   ")) }
        #expect(throws: EPUBBuildError.self) { _ = try build(BookMetadata(title: "T", uniqueIdentifier: " ")) }
        let (epub, _, _) = try build(BookMetadata(title: "T", languageTag: "ja-JP"))
        let opf = try xml(epub, "OEBPS/package.opf")
        #expect(try strings(opf, "//*[local-name()='language']") == ["ja-JP"])
        let id = try #require(try strings(opf, "//*[local-name()='identifier']").first)
        #expect(id.hasPrefix("urn:uuid:") && UUID(uuidString: String(id.dropFirst(9))) != nil)
    }

    // UT-015
    @Test func manifestMatchesArchiveContents() throws {
        let (epub, result, _) = try build(BookMetadata(title: "T"), pages: 5, cover: true)
        let opf = try xml(epub, "OEBPS/package.opf")
        let hrefs = try strings(opf, "//*[local-name()='manifest']/*[local-name()='item']/@href")
        let ids = try strings(opf, "//*[local-name()='manifest']/*[local-name()='item']/@id")
        #expect(Set(ids).count == ids.count)
        #expect(Set(hrefs).count == hrefs.count)
        let entries = Set(result.entryPaths)
        for h in hrefs { #expect(entries.contains("OEBPS/" + h), "missing \(h)") }
        // manifest外のファイルはmimetype/container/opfのみ
        let unlisted = entries.subtracting(hrefs.map { "OEBPS/" + $0 })
        #expect(unlisted == ["mimetype", "META-INF/container.xml", "OEBPS/package.opf"])
        // spine idref は manifest に存在
        let idrefs = try strings(opf, "//*[local-name()='spine']/*[local-name()='itemref']/@idref")
        for r in idrefs { #expect(ids.contains(r)) }
        #expect(result.entryPaths.count == Set(result.entryPaths).count)
    }

    // UT-006
    @Test func coverIsSeparateAndFirstInSpine() throws {
        let (epub, _, _) = try build(BookMetadata(title: "T"), pages: 4, cover: true)
        let opf = try xml(epub, "OEBPS/package.opf")
        let idrefs = try strings(opf, "//*[local-name()='spine']/*[local-name()='itemref']/@idref")
        #expect(idrefs == ["cover-page", "page-0001", "page-0002", "page-0003", "page-0004"])
        #expect(try strings(opf, "//*[local-name()='item'][@properties='cover-image']/@href") == ["images/cover.jpg"])
    }

    @Test func noCoverOmitsCoverItems() throws {
        let (epub, result, _) = try build(BookMetadata(title: "T"), pages: 2)
        let opf = try xml(epub, "OEBPS/package.opf")
        #expect(try strings(opf, "//*[local-name()='item'][@properties='cover-image']").isEmpty)
        #expect(!result.entryPaths.contains { $0.contains("cover") })
        #expect(try strings(opf, "//*[local-name()='spine']/*[local-name()='itemref']/@idref") == ["page-0001", "page-0002"])
    }

    // UT-017
    @Test(arguments: [ReadingDirection.ltr, .rtl])
    func navAndSpineDirectionAndLayout(_ dir: ReadingDirection) throws {
        let (epub, _, _) = try build(BookMetadata(title: "T", readingDirection: dir), cover: true)
        let opf = try xml(epub, "OEBPS/package.opf")
        #expect(try strings(opf, "//*[local-name()='spine']/@page-progression-direction") == [dir.rawValue])
        #expect(try strings(opf, "//*[local-name()='meta'][@property='rendition:layout']") == ["pre-paginated"])
        #expect(try strings(opf, "//*[local-name()='item'][@properties='nav']/@href") == ["nav.xhtml"])
        let nav = try xml(epub, "OEBPS/nav.xhtml")
        #expect(try nav.nodes(forXPath: "//*[local-name()='nav'][@*[local-name()='type']='toc']").count == 1)
        let navHrefs = try strings(nav, "//*[local-name()='a']/@href")
        #expect(navHrefs == ["pages/cover.xhtml", "pages/page-0001.xhtml"])
    }

    @Test func pageXHTMLUsesOutputPixelDimensionsAndInternalNamesOnly() throws {
        let (epub, _, _) = try build(BookMetadata(title: "T"), pages: 2, mixed: true)
        let p2 = try xml(epub, "OEBPS/pages/page-0002.xhtml")
        #expect(try strings(p2, "//*[local-name()='meta'][@name='viewport']/@content") == ["width=1800,height=1200"])
        #expect(try strings(p2, "//*[local-name()='img']/@src") == ["../images/page-0002.jpg"])
        #expect(!String(decoding: try TestSupport.unzipEntry(epub, "OEBPS/pages/page-0002.xhtml"), as: UTF8.self).contains("src-1"))
    }

    @Test func userFilenamesNeverLeakIntoArchivePaths() throws {
        let (_, result, fx) = try build(BookMetadata(title: "T"), pages: 3)
        for f in fx.sourceFiles { #expect(!result.entryPaths.contains { $0.contains(f.deletingPathExtension().lastPathComponent) }) }
    }

    @Test func warningsAreReportedSeparately() throws {
        let (_, r, _) = try build(BookMetadata(title: "T"), pages: 3, mixed: true)
        let codes = Set(r.issues.map(\.code))
        #expect(codes.contains("PM-A11Y-001"))      // alt未設定は警告 (空altで黙らせない)
        #expect(codes.contains("PM-QUAL-001"))      // 縦横比混在
        #expect(codes.contains("PM-META-006"))      // 著者未設定
        let (_, r2, _) = try build(BookMetadata(title: "T", creator: "C"), pages: 2, alt: "説明")
        #expect(!r2.issues.contains { $0.code == "PM-A11Y-001" })
    }

    @Test func altTextIsEscapedIntoAttribute() throws {
        let (epub, _, _) = try build(BookMetadata(title: "T"), pages: 1, alt: "say \"hi\" <&>")
        let p = try xml(epub, "OEBPS/pages/page-0001.xhtml")
        #expect(try strings(p, "//*[local-name()='img']/@alt") == ["say \"hi\" <&>"])
    }

    // UT-008 / 元画像不変
    @Test func sourceImagesAreNotModified() throws {
        let fx = try TestSupport.makeFixture(pages: 4, cover: true)
        let before = try fx.sourceFiles.map { try TestSupport.sha256($0) }
        let mtimes = try fx.sourceFiles.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        let dirListing = try FileManager.default.contentsOfDirectory(atPath: fx.dir.path).sorted()
        try EPUBBuilder().build(
            EPUBBookInput(metadata: BookMetadata(title: "T"), cover: fx.cover, pages: fx.pages),
            to: fx.dir.appendingPathComponent("o.epub"))
        #expect(try fx.sourceFiles.map { try TestSupport.sha256($0) } == before)
        #expect(try fx.sourceFiles.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date } == mtimes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.dir.path).sorted() == (dirListing + ["o.epub"]).sorted())
    }

    @Test func noPagesIsRejected() throws {
        let dir = try TestSupport.makeTempDir()
        #expect(throws: EPUBBuildError.noPages) {
            try EPUBBuilder().build(EPUBBookInput(metadata: BookMetadata(title: "T"), cover: nil, pages: []), to: dir.appendingPathComponent("x.epub"))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.epub").path))
    }
}

@Suite("Failure recovery")
struct FailureRecoveryTests {
    // US-07 / IT-008
    @Test func cancellationLeavesNoPartialEPUB() async throws {
        let fx = try TestSupport.makeFixture(pages: 3)
        let out = fx.dir.appendingPathComponent("c.epub")
        let input = EPUBBookInput(metadata: BookMetadata(title: "T"), cover: nil, pages: fx.pages)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try EPUBBuilder().build(input, to: out)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func missingSourceImageLeavesNoPartialEPUB() throws {
        let fx = try TestSupport.makeFixture(pages: 3)
        try FileManager.default.removeItem(at: fx.pages[1].fileURL)
        let out = fx.dir.appendingPathComponent("m.epub")
        #expect(throws: (any Error).self) {
            try EPUBBuilder().build(EPUBBookInput(metadata: BookMetadata(title: "T"), cover: nil, pages: fx.pages), to: out)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}

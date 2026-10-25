import Foundation

public enum EPUBImageKind: String, Sendable {
    case jpeg, png

    var mimeType: String { self == .jpeg ? "image/jpeg" : "image/png" }
    var fileExtension: String { self == .jpeg ? "jpg" : "png" }
}

/// ステージング済みの出力画像 (最適化後)。元画像ではない。
public struct EPUBImageAsset: Sendable {
    public let fileURL: URL
    public let kind: EPUBImageKind
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let altText: String?

    public init(fileURL: URL, kind: EPUBImageKind, pixelWidth: Int, pixelHeight: Int, altText: String? = nil) {
        self.fileURL = fileURL
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.altText = altText
    }
}

public struct EPUBBookInput: Sendable {
    public let metadata: BookMetadata
    public let cover: EPUBImageAsset?
    public let pages: [EPUBImageAsset]
    public let modifiedAt: Date

    public init(metadata: BookMetadata, cover: EPUBImageAsset?, pages: [EPUBImageAsset], modifiedAt: Date = Date()) {
        self.metadata = metadata
        self.cover = cover
        self.pages = pages
        self.modifiedAt = modifiedAt
    }
}

public struct EPUBBuildResult: Sendable {
    public let issues: [Issue]
    /// ZIP内の物理順エントリ名
    public let entryPaths: [String]
    public let byteCount: Int64
}

public enum EPUBBuildError: Error, Equatable, Sendable {
    case noPages
    case invalidMetadata([String])
    case invalidImageSize(String)
    case tooManyPages(Int)
    case archiveNonCompliant([String])
}

/// 画像1点=1ページのEPUB 3 Fixed Layoutを生成する (設計書 §9)。
/// ユーザーのファイル名は内部パスに一切使わず、連番にマッピングする。
public struct EPUBBuilder: Sendable {
    public static let maxPages = 2000
    public init() {}

    @discardableResult
    public func build(_ input: EPUBBookInput, to destination: URL) throws -> EPUBBuildResult {
        guard !input.pages.isEmpty else { throw EPUBBuildError.noPages }
        guard input.pages.count <= Self.maxPages else { throw EPUBBuildError.tooManyPages(input.pages.count) }
        let metaIssues = BookMetadataValidator.validate(input.metadata)
        let blocking = metaIssues.filter { $0.severity == .error || $0.severity == .fatal }
        guard blocking.isEmpty else { throw EPUBBuildError.invalidMetadata(blocking.map(\.code)) }
        for (i, p) in ([input.cover].compactMap { $0 } + input.pages).enumerated() {
            guard p.pixelWidth > 0, p.pixelHeight > 0 else {
                throw EPUBBuildError.invalidImageSize("asset #\(i)")
            }
        }

        var issues = metaIssues.filter { $0.severity == .warning }
        issues += qualityIssues(for: input)

        var writer: EPUBArchiveWriter?
        do {
            writer = try EPUBArchiveWriter(destination: destination, timestamp: input.modifiedAt)
            guard let writer else { throw ArchiveError.closed }
            try Task.checkCancellation()
            try writer.addEntry(path: "META-INF/container.xml", data: Data(Self.containerXML.utf8), compression: .deflate)
            try writer.addEntry(path: "OEBPS/package.opf", data: Data(try packageOPF(input).utf8), compression: .deflate)
            try writer.addEntry(path: "OEBPS/nav.xhtml", data: Data(try navXHTML(input).utf8), compression: .deflate)
            try writer.addEntry(path: "OEBPS/styles/pages.css", data: Data(Self.css.utf8), compression: .deflate)

            if let cover = input.cover {
                let xhtml = try pageXHTML(title: "表紙", image: cover, imagePath: "../images/cover.\(cover.kind.fileExtension)", language: input.metadata.languageTag)
                try writer.addEntry(path: "OEBPS/pages/cover.xhtml", data: Data(xhtml.utf8), compression: .deflate)
            }
            for (i, page) in input.pages.enumerated() {
                try Task.checkCancellation()
                let n = Self.pageNumber(i)
                let xhtml = try pageXHTML(
                    title: "\(i + 1)ページ", image: page,
                    imagePath: "../images/page-\(n).\(page.kind.fileExtension)", language: input.metadata.languageTag)
                try writer.addEntry(path: "OEBPS/pages/page-\(n).xhtml", data: Data(xhtml.utf8), compression: .deflate)
            }
            if let cover = input.cover {
                try writer.addStoredFile(path: "OEBPS/images/cover.\(cover.kind.fileExtension)", from: cover.fileURL)
            }
            for (i, page) in input.pages.enumerated() {
                try Task.checkCancellation()
                try writer.addStoredFile(
                    path: "OEBPS/images/page-\(Self.pageNumber(i)).\(page.kind.fileExtension)", from: page.fileURL)
            }
            try writer.finish()
            try Task.checkCancellation()

            // 生成後の自前OCF検査。違反があれば成功として返さず、出力を残さない。
            let inspection = try EPUBArchiveInspector.inspect(url: destination)
            guard inspection.isCompliant else {
                throw EPUBBuildError.archiveNonCompliant(inspection.violations.map(\.code))
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return EPUBBuildResult(issues: issues, entryPaths: inspection.entries.map(\.name), byteCount: size)
        } catch {
            // 全失敗経路(初期化・生成・検査・キャンセル)で書きかけのEPUBを残さない (US-07)
            writer?.abort()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: Documents

    static func pageNumber(_ index: Int) -> String { String(format: "%04d", index + 1) }

    static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>

    """

    static let css = """
    html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; }
    body { display: block; }
    img { display: block; width: 100%; height: 100%; object-fit: contain; }

    """

    func packageOPF(_ input: EPUBBookInput) throws -> String {
        let m = input.metadata
        let esc = EPUBXMLSerializer.escape
        var meta = ""
        meta += "    <dc:identifier id=\"pub-id\">\(try esc(m.uniqueIdentifier))</dc:identifier>\n"
        meta += "    <dc:title id=\"title\">\(try esc(m.title))</dc:title>\n"
        meta += "    <meta refines=\"#title\" property=\"title-type\">main</meta>\n"
        if let sub = m.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty {
            meta += "    <dc:title id=\"subtitle\">\(try esc(sub))</dc:title>\n"
            meta += "    <meta refines=\"#subtitle\" property=\"title-type\">subtitle</meta>\n"
            meta += "    <meta refines=\"#subtitle\" property=\"display-seq\">2</meta>\n"
        }
        meta += "    <dc:language>\(try esc(m.languageTag))</dc:language>\n"
        if let c = m.creator?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            meta += "    <dc:creator>\(try esc(c))</dc:creator>\n"
        }
        if let p = m.publisher?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            meta += "    <dc:publisher>\(try esc(p))</dc:publisher>\n"
        }
        if let d = m.description, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meta += "    <dc:description>\(try esc(d))</dc:description>\n"
        }
        meta += "    <meta property=\"dcterms:modified\">\(Self.utcTimestamp(input.modifiedAt))</meta>\n"
        // rendition は予約済みprefixのため宣言しない (docs/decisions/ADR-011 参照)
        meta += "    <meta property=\"rendition:layout\">pre-paginated</meta>\n"
        meta += "    <meta property=\"rendition:spread\">none</meta>\n"

        var manifest = "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        manifest += "    <item id=\"css\" href=\"styles/pages.css\" media-type=\"text/css\"/>\n"
        var spine = ""
        if let cover = input.cover {
            manifest += "    <item id=\"cover-image\" href=\"images/cover.\(cover.kind.fileExtension)\" media-type=\"\(cover.kind.mimeType)\" properties=\"cover-image\"/>\n"
            manifest += "    <item id=\"cover-page\" href=\"pages/cover.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "    <itemref idref=\"cover-page\"/>\n"
        }
        for (i, page) in input.pages.enumerated() {
            let n = Self.pageNumber(i)
            manifest += "    <item id=\"image-\(n)\" href=\"images/page-\(n).\(page.kind.fileExtension)\" media-type=\"\(page.kind.mimeType)\"/>\n"
            manifest += "    <item id=\"page-\(n)\" href=\"pages/page-\(n).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "    <itemref idref=\"page-\(n)\"/>\n"
        }

        var doc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        doc += "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"pub-id\">\n"
        doc += "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n" + meta + "  </metadata>\n"
        doc += "  <manifest>\n" + manifest + "  </manifest>\n"
        doc += "  <spine page-progression-direction=\"\(m.readingDirection.rawValue)\">\n" + spine + "  </spine>\n"
        doc += "</package>\n"
        return doc
    }

    func navXHTML(_ input: EPUBBookInput) throws -> String {
        let lang = try EPUBXMLSerializer.escape(input.metadata.languageTag)
        var items = ""
        if input.cover != nil { items += "        <li><a href=\"pages/cover.xhtml\">表紙</a></li>\n" }
        items += "        <li><a href=\"pages/page-0001.xhtml\">本文</a></li>\n"
        var doc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        doc += "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" xml:lang=\"\(lang)\" lang=\"\(lang)\">\n"
        doc += "  <head><title>目次</title></head>\n  <body>\n"
        doc += "    <nav epub:type=\"toc\" id=\"toc\">\n      <h1>目次</h1>\n      <ol>\n" + items + "      </ol>\n    </nav>\n"
        doc += "  </body>\n</html>\n"
        return doc
    }

    func pageXHTML(title: String, image: EPUBImageAsset, imagePath: String, language: String) throws -> String {
        let esc = EPUBXMLSerializer.escape
        let lang = try esc(language)
        let alt = try esc(image.altText ?? "")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(lang)" lang="\(lang)">
          <head>
            <title>\(try esc(title))</title>
            <meta name="viewport" content="width=\(image.pixelWidth),height=\(image.pixelHeight)"/>
            <link rel="stylesheet" type="text/css" href="../styles/pages.css"/>
          </head>
          <body>
            <img src="\(imagePath)" alt="\(alt)" width="\(image.pixelWidth)" height="\(image.pixelHeight)"/>
          </body>
        </html>

        """
    }

    // MARK: Warnings (PageMint独自。EPUBCheck結果とは別区分)

    private func qualityIssues(for input: EPUBBookInput) -> [Issue] {
        var out: [Issue] = []
        let missingAlt = input.pages.filter { ($0.altText ?? "").isEmpty }.count
        if missingAlt > 0 {
            out.append(Issue(
                category: "a11y", severity: .warning, code: "PM-A11Y-001",
                message: "\(missingAlt)ページに代替テキストがありません。画像のみのEPUBはスクリーンリーダーで内容が伝わりません。"))
        }
        let ratios = input.pages.map { Double($0.pixelWidth) / Double($0.pixelHeight) }
        if let lo = ratios.min(), let hi = ratios.max(), hi / lo > 1.01 {
            out.append(Issue(
                category: "quality", severity: .warning, code: "PM-QUAL-001",
                message: "縦横比の異なるページが混在しています。ページ単位のviewportで保持し、クロップ・変形はしません。"))
        }
        return out
    }

    static func utcTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")!
        return f.string(from: date)
    }
}

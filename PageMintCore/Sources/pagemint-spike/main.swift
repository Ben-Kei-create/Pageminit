import Foundation
import PageMintCore

// Phase 0 スパイクCLI: 合成画像から最小FXL EPUBを生成し、OCFヘッダを自前検査する。
// 使い方: pagemint-spike <出力.epub> [ページ数=3] [--rtl] [--cover]
// EPUBCheckは別途: java -jar epubcheck.jar <出力.epub>

let args = CommandLine.arguments.dropFirst()
guard let outPath = args.first else {
    FileHandle.standardError.write(Data("usage: pagemint-spike <out.epub> [pages] [--rtl] [--cover]\n".utf8))
    exit(64)
}
let pageCount = args.dropFirst().compactMap { Int($0) }.first ?? 3
let rtl = args.contains("--rtl")
let withCover = args.contains("--cover")

let work = FileManager.default.temporaryDirectory.appendingPathComponent("pagemint-spike-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

func asset(_ name: String, png: Bool, w: Int, h: Int, hue: CGFloat) throws -> EPUBImageAsset {
    let url = work.appendingPathComponent(name)
    if png { try SampleImageFactory.writePNG(to: url, width: w, height: h, hue: hue) }
    else { try SampleImageFactory.writeJPEG(to: url, width: w, height: h, hue: hue) }
    return EPUBImageAsset(fileURL: url, kind: png ? .png : .jpeg, pixelWidth: w, pixelHeight: h)
}

let pages = try (0..<pageCount).map { i in
    try asset("p\(i).\(i % 2 == 0 ? "png" : "jpg")", png: i % 2 == 0, w: 1200, h: 1800, hue: CGFloat(i % 10) / 10)
}
let cover = withCover ? try asset("cover.jpg", png: false, w: 1200, h: 1800, hue: 0.8) : nil
let meta = BookMetadata(
    title: "PageMint スパイク & <テスト>", subtitle: "Phase 0", creator: "PageMint",
    languageTag: "ja", readingDirection: rtl ? .rtl : .ltr)

let out = URL(fileURLWithPath: outPath)
let result = try EPUBBuilder().build(EPUBBookInput(metadata: meta, cover: cover, pages: pages), to: out)
let inspection = try EPUBArchiveInspector.inspect(url: out)
print("wrote \(out.path) (\(result.byteCount) bytes, \(result.entryPaths.count) entries)")
print("OCF self-check: \(inspection.isCompliant ? "OK" : "NG")")
for v in inspection.violations { print("  \(v.code): \(v.message)") }
for i in result.issues { print("  [\(i.severity.rawValue)] \(i.code): \(i.message)") }
exit(inspection.isCompliant ? 0 : 1)

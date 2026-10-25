import CryptoKit
import Foundation
import PageMintCore

enum TestSupport {
    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// 独立検証として macOS 標準の unzip を使う。
    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, out: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    static func unzipEntry(_ epub: URL, _ path: String) throws -> Data {
        try run("/usr/bin/unzip", ["-p", epub.path, path]).out
    }

    static func unzipList(_ epub: URL) throws -> [String] {
        String(decoding: try run("/usr/bin/unzip", ["-Z1", epub.path]).out, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    struct Fixture {
        let dir: URL
        let pages: [EPUBImageAsset]
        let cover: EPUBImageAsset?
        let sourceFiles: [URL]
    }

    static func makeFixture(pages: Int = 3, cover: Bool = false, mixedRatios: Bool = false, alt: String? = nil) throws -> Fixture {
        let dir = try makeTempDir()
        var assets: [EPUBImageAsset] = []
        var files: [URL] = []
        for i in 0..<pages {
            let png = i % 2 == 0
            let url = dir.appendingPathComponent("src-\(i).\(png ? "png" : "jpg")")
            let (w, h) = (mixedRatios && i == 1) ? (1800, 1200) : (1200, 1800)
            if png { try SampleImageFactory.writePNG(to: url, width: w, height: h) }
            else { try SampleImageFactory.writeJPEG(to: url, width: w, height: h) }
            assets.append(EPUBImageAsset(fileURL: url, kind: png ? .png : .jpeg, pixelWidth: w, pixelHeight: h, altText: alt))
            files.append(url)
        }
        var coverAsset: EPUBImageAsset?
        if cover {
            let url = dir.appendingPathComponent("cover-src.jpg")
            try SampleImageFactory.writeJPEG(to: url, width: 1200, height: 1800)
            coverAsset = EPUBImageAsset(fileURL: url, kind: .jpeg, pixelWidth: 1200, pixelHeight: 1800)
            files.append(url)
        }
        return Fixture(dir: dir, pages: assets, cover: coverAsset, sourceFiles: files)
    }
}

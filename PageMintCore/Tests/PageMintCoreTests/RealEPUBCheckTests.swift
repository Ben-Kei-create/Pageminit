import Foundation
import Testing
@testable import PageMintCore

/// 実EPUBCheck 5.4.0 の出力(docs/test-fixtures/epubcheck-5.4.0)に対する検証。
@Suite("EPUBCheck 5.4.0 real output")
struct RealEPUBCheckTests {
    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/test-fixtures/epubcheck-5.4.0")
    }

    @Test func parsesRealPassingReport() throws {
        let raw = try Data(contentsOf: Self.fixtures.appendingPathComponent("pass.json"))
        let r = EPUBCheckReportParser.parse(json: raw, exitCode: 0)
        #expect(r.status == .passed && r.toolVersion == "5.4.0" && r.errorCount == 0)
    }

    @Test func parsesRealErrorReport() throws {
        let raw = try Data(contentsOf: Self.fixtures.appendingPathComponent("error.json"))
        let r = EPUBCheckReportParser.parse(json: raw, exitCode: 1)
        #expect(r.status == .failed && r.errorCount == 1)
        #expect(r.messages.first?.id == "RSC-001" && r.messages.first?.path == "OEBPS/nav.xhtml")
        #expect(r.messages.first?.line == nil)   // EPUBCheckは行不明を -1 で返す
        #expect(EPUBCheckReportParser.parse(json: raw, exitCode: 0).status != .passed)
    }

    /// 環境変数 PAGEMINT_JAVA / PAGEMINT_EPUBCHECK_JAR があるときだけ、実プロセスで end-to-end 検証する。
    @Test func endToEndWithRealRuntime() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let java = env["PAGEMINT_JAVA"], let jar = env["PAGEMINT_EPUBCHECK_JAR"] else {
            print("SKIPPED: PAGEMINT_JAVA / PAGEMINT_EPUBCHECK_JAR 未設定 (未検証扱い)")
            return
        }
        let work = try TestSupport.makeTempDir()
        let runner = ProcessEPUBCheckRunner(
            executableURL: URL(fileURLWithPath: java), leadingArguments: ["-jar", jar], workDirectory: work, timeout: 120)
        #expect(await runner.queryVersion()?.contains("5.4.0") == true)

        let fx = try TestSupport.makeFixture(pages: 4, cover: true)
        let good = fx.dir.appendingPathComponent("good.epub")
        try EPUBBuilder().build(
            EPUBBookInput(metadata: BookMetadata(title: "T & <U>", subtitle: "S", creator: "C", readingDirection: .rtl),
                          cover: fx.cover, pages: fx.pages), to: good)
        let ok = await runner.validate(epubURL: good)
        #expect(ok.status == .passed, "\(ok.messages)")
        #expect(ok.errorCount == 0 && ok.warningCount == 0, "\(ok.messages)")

        // nav を欠落させたEPUBは必ず failed になる
        let bad = fx.dir.appendingPathComponent("bad.epub")
        try FileManager.default.copyItem(at: good, to: bad)
        #expect(try TestSupport.run("/usr/bin/zip", ["-q", "-d", bad.path, "OEBPS/nav.xhtml"]).status == 0)
        let ng = await runner.validate(epubURL: bad)
        #expect(ng.status == .failed && ng.errorCount >= 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }
}

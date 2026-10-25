import Foundation
import Testing
@testable import PageMintCore

/// UT-018 / IT-010。実EPUBCheckではなく、シェルスクリプトの偽ランナーで
/// 「どの異常系も合格にならない」ことを検証する。実JSONでの検証は未実施 (docs/phase0-report.md)。
@Suite("EPUBCheck runner")
struct EPUBCheckRunnerTests {
    private func fakeJava(body: String) throws -> (runner: ProcessEPUBCheckRunner, dir: URL, epub: URL) {
        let dir = try TestSupport.makeTempDir()
        let script = dir.appendingPathComponent("fake-java.sh")
        let text = """
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--json" ]; then out="$2"; shift; fi
          shift
        done
        \(body)
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let epub = dir.appendingPathComponent("x.epub")
        try Data("dummy".utf8).write(to: epub)
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (ProcessEPUBCheckRunner(executableURL: script, leadingArguments: [], workDirectory: work, timeout: 5), dir, epub)
    }

    private func json(errors: Int = 0, fatals: Int = 0, warnings: Int = 0, version: String = "5.4.0") -> String {
        func m(_ sev: String, _ id: String) -> [String: Any] {
            ["ID": id, "severity": sev, "message": "m", "additionalLocations": 0,
             "locations": [["path": "OEBPS/package.opf", "line": 3, "column": 4]]]
        }
        var msgs: [[String: Any]] = []
        for _ in 0..<errors { msgs.append(m("ERROR", "RSC-005")) }
        for _ in 0..<fatals { msgs.append(m("FATAL", "PKG-008")) }
        for _ in 0..<warnings { msgs.append(m("WARNING", "OPF-003")) }
        let root: [String: Any] = [
            "messages": msgs,
            "checker": ["checkerVersion": version, "nError": errors, "nFatal": fatals, "nWarning": warnings],
        ]
        let data = try! JSONSerialization.data(withJSONObject: root)
        return String(decoding: data, as: UTF8.self)
    }

    private func writing(_ json: String, exit code: Int) -> String {
        "cat > \"$out\" <<'EOF'\n\(json)\nEOF\nexit \(code)"
    }

    @Test func passWithWarnings() async throws {
        let (r, _, epub) = try fakeJava(body: writing(json(warnings: 2), exit: 0))
        let rep = await r.validate(epubURL: epub)
        #expect(rep.status == .passed)
        #expect(rep.errorCount == 0 && rep.warningCount == 2)
        #expect(rep.toolVersion == "5.4.0")
        #expect(rep.messages.first?.path == "OEBPS/package.opf" && rep.messages.first?.line == 3)
    }

    @Test func errorsFail() async throws {
        let (r, _, epub) = try fakeJava(body: writing(json(errors: 2, fatals: 1, warnings: 1), exit: 1))
        let rep = await r.validate(epubURL: epub)
        #expect(rep.status == .failed)
        #expect(rep.errorCount == 3 && rep.warningCount == 1)
    }

    @Test func exitZeroButErrorsInJSONIsNeverPass() async throws {
        let (r, _, epub) = try fakeJava(body: writing(json(errors: 1), exit: 0))
        let rep = await r.validate(epubURL: epub)
        #expect(rep.status != .passed)
    }

    @Test func exitOneButNoErrorsIsNeverPass() async throws {
        let (r, _, epub) = try fakeJava(body: writing(json(), exit: 1))
        #expect(await r.validate(epubURL: epub).status != .passed)
    }

    @Test func aggregateMismatchIsNeverPass() async throws {
        let bad = #"{"messages":[],"checker":{"checkerVersion":"5.4.0","nError":3,"nFatal":0,"nWarning":0}}"#
        let (r, _, epub) = try fakeJava(body: writing(bad, exit: 0))
        #expect(await r.validate(epubURL: epub).status != .passed)
    }

    @Test(arguments: [2, 3, 127, 255])
    func abnormalExitIsUnavailable(_ code: Int) async throws {
        let (r, _, epub) = try fakeJava(body: writing(json(), exit: code))
        guard case .unavailable = await r.validate(epubURL: epub).status else { Issue.record("expected unavailable"); return }
    }

    @Test func malformedJSONIsUnavailable() async throws {
        let (r, _, epub) = try fakeJava(body: writing("{not json", exit: 0))
        guard case .unavailable = await r.validate(epubURL: epub).status else { Issue.record("expected unavailable"); return }
    }

    @Test func missingReportIsUnavailable() async throws {
        let (r, _, epub) = try fakeJava(body: "exit 0")
        guard case .unavailable = await r.validate(epubURL: epub).status else { Issue.record("expected unavailable"); return }
    }

    @Test func launchFailureIsUnavailable() async throws {
        let dir = try TestSupport.makeTempDir()
        let r = ProcessEPUBCheckRunner(
            executableURL: dir.appendingPathComponent("no-such-java"), leadingArguments: [], workDirectory: dir)
        guard case .unavailable = await r.validate(epubURL: dir.appendingPathComponent("x.epub")).status else {
            Issue.record("expected unavailable"); return
        }
    }

    @Test func timeoutKillsProcessAndIsUnavailable() async throws {
        let (r0, _, epub) = try fakeJava(body: "sleep 30")
        let r = ProcessEPUBCheckRunner(
            executableURL: r0.executableURL, leadingArguments: [], workDirectory: r0.workDirectory, timeout: 1)
        let start = Date()
        let rep = await r.validate(epubURL: epub)
        #expect(Date().timeIntervalSince(start) < 10)
        guard case .unavailable(let reason) = rep.status else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("タイムアウト"))
    }

    @Test func versionQuery() async throws {
        let (r, _, _) = try fakeJava(body: "echo 'EPUBCheck v5.4.0'")
        #expect(await r.queryVersion() == "EPUBCheck v5.4.0")
        let (r2, _, _) = try fakeJava(body: "exit 3")
        #expect(await r2.queryVersion() == nil)
    }

    @Test func unknownSeverityFailsSafe() {
        let raw = Data(#"{"messages":[{"ID":"X-1","severity":"WEIRD","message":"m"}],"checker":{"nError":0,"nFatal":0}}"#.utf8)
        let rep = EPUBCheckReportParser.parse(json: raw, exitCode: 0)
        #expect(rep.status != .passed)
    }

    @Test func workDirectoryIsCleanedUp() async throws {
        let (r, _, epub) = try fakeJava(body: writing(json(), exit: 0))
        _ = await r.validate(epubURL: epub)
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.workDirectory.path).isEmpty)
    }

    // レビュー指摘 P1: 必須項目の欠落・型不正は合格にならない
    @Test(arguments: [
        #"{"messages":[]}"#,
        #"{"messages":[],"checker":{}}"#,
        #"{"messages":[],"checker":{"nError":0}}"#,
        #"{"messages":[],"checker":{"nError":"0","nFatal":0}}"#,
        #"{"messages":[],"checker":{"nError":0,"nFatal":0,"nWarning":"x"}}"#,
        #"{"messages":[],"checker":{"nError":0,"nFatal":0,"nWarning":2}}"#,
        #"{"checker":{"nError":0,"nFatal":0}}"#,
        #"{"messages":[{"severity":"WARNING"}],"checker":{"nError":0,"nFatal":0}}"#,
        #"[]"#,
    ])
    func incompleteJSONIsNeverPass(_ json: String) {
        let r = EPUBCheckReportParser.parse(json: Data(json.utf8), exitCode: 0)
        guard case .unavailable = r.status else { Issue.record("expected unavailable for \(json)"); return }
    }

    // レビュー指摘 P2: SIGTERMを無視する検証器もキャンセルで速やかに終了する
    @Test func cancellationKillsProcessIgnoringSIGTERM() async throws {
        let (r0, _, epub) = try fakeJava(body: "trap '' TERM\nwhile true; do sleep 1; done")
        let r = ProcessEPUBCheckRunner(
            executableURL: r0.executableURL, leadingArguments: [], workDirectory: r0.workDirectory, timeout: 120)
        let start = Date()
        let task = Task { await r.validate(epubURL: epub) }
        try await Task.sleep(for: .seconds(1))
        task.cancel()
        let rep = await task.value
        #expect(Date().timeIntervalSince(start) < 15)
        guard case .unavailable = rep.status else { Issue.record("expected unavailable"); return }
    }
}

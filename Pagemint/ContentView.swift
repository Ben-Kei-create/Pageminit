import PageMintCore
import OSLog
import SwiftUI

/// Phase 0 のプレースホルダ。本実装のUIはPhase 1以降 (設計書 §15)。
/// 生成コアがアプリにリンクされ、Sandbox内で最小EPUBを作って自前OCF検査できることだけを確認する。
struct ContentView: View {
    @State private var spikeResult: String = "未実行"
    private let autoValidate = CommandLine.arguments.contains("--spike-validate")

    var body: some View {
        VStack(spacing: 16) {
            Text("PageMint").font(.largeTitle.bold())
            Text("画像を、本にする。").foregroundStyle(.secondary)
            Divider().frame(width: 240)
            Text("Phase 0 スパイク").font(.headline)
            Button("最小EPUBを生成してOCF自己検査") {
                spikeResult = Self.runSpike()
            }
            Text(spikeResult)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
            Button("同梱EPUBCheckで検証") { Task { spikeResult = await Self.runValidation() } }
            Text("EPUBCheck: Resources/ValidationRuntime が無ければ「検証不可」").font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
        .task {
            guard autoValidate else { return }
            let r = await Self.runValidation()
            spikeResult = r
            Logger(subsystem: "PageMint", category: "spike").notice("PM-SPIKE-RESULT \(r, privacy: .public)")
            try? r.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("spike-result.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Phase 0 スパイク: Sandbox内から同梱JRE+EPUBCheckを起動できるか。ランタイムが無ければ検証不可。
    static func runValidation() async -> String {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("ValidationRuntime"),
              FileManager.default.fileExists(atPath: root.path)
        else { return "検証不可: 同梱ランタイムなし" }
        let java = root.appendingPathComponent("jre/bin/java")
        let jar = root.appendingPathComponent("epubcheck/epubcheck.jar")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pm-val-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let img = work.appendingPathComponent("p.png")
            try SampleImageFactory.writePNG(to: img, width: 600, height: 900)
            let out = work.appendingPathComponent("v.epub")
            try EPUBBuilder().build(EPUBBookInput(
                metadata: BookMetadata(title: "Spike", creator: "PageMint"), cover: nil,
                pages: [EPUBImageAsset(fileURL: img, kind: .png, pixelWidth: 600, pixelHeight: 900, altText: "sample")]), to: out)
            let runner = ProcessEPUBCheckRunner(
                executableURL: java, leadingArguments: ["-jar", jar.path], workDirectory: work, timeout: 120)
            let version = await runner.queryVersion() ?? "version取得失敗"
            let report = await runner.validate(epubURL: out)
            return "\(version)\n\(report.status) errors=\(report.errorCount) warnings=\(report.warningCount)"
        } catch { return "失敗: \(error)" }
    }

    private static func runSpike() -> String {
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pm-spike-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let img = dir.appendingPathComponent("p.png")
            try SampleImageFactory.writePNG(to: img, width: 600, height: 900)
            let asset = EPUBImageAsset(fileURL: img, kind: .png, pixelWidth: 600, pixelHeight: 900)
            let out = dir.appendingPathComponent("spike.epub")
            let result = try EPUBBuilder().build(
                EPUBBookInput(metadata: BookMetadata(title: "Spike"), cover: nil, pages: [asset]), to: out)
            let ins = try EPUBArchiveInspector.inspect(url: out)
            return "\(result.byteCount) bytes / \(result.entryPaths.count) entries\nOCF自己検査: \(ins.isCompliant ? "OK" : "NG \(ins.violations.map(\.code))")"
        } catch {
            return "失敗: \(error)"
        }
    }
}

#Preview { ContentView() }

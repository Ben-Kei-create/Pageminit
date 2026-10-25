import PageMintCore
import SwiftUI

/// Phase 0 のプレースホルダ。本実装のUIはPhase 1以降 (設計書 §15)。
/// 生成コアがアプリにリンクされ、Sandbox内で最小EPUBを作って自前OCF検査できることだけを確認する。
struct ContentView: View {
    @State private var spikeResult: String = "未実行"

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
            Text("EPUBCheck: 未組込み (検証不可)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
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

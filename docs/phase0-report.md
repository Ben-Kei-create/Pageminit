# Phase 0 レポート (実装担当 → レビュー担当)

日付: 2026-10-25 / ブランチ: `phase0-spike` / 設計書: PageMint_Detailed_Design_v1.0 §15

## 構成
- `Pagemint.xcodeproj` … macOS専用 (deployment 15.0, Swift 6, App Sandbox + user-selected read-write, ネットワーク無効, Hardened Runtime)。ローカルSwiftPackage `PageMintCore` をリンク。
- `PageMintCore/` … Swift Package (生成コア)。`swift test` で単体実行可能。
  - `EPUBArchiveWriter` / `EPUBArchiveInspector` / `EPUBXMLSerializer` / `BookMetadataValidator` / `EPUBBuilder` / `ProcessEPUBCheckRunner` + `EPUBCheckReportParser`
  - `pagemint-spike` CLI: `swift run pagemint-spike out.epub 5 --cover --rtl`
- 設計書のフォルダ案 `PageMintApp/` ではなく、既存テンプレートの `Pagemint/` をそのまま使用 (同期グループ)。

## 実行したテスト (すべて実行済み)
`cd PageMintCore && swift test` → **40テスト / 4スイート合格** (macOS 27 / Xcode 27.1 / Swift 6.4)。
`xcodebuild -scheme Pagemint -destination 'platform=macOS' build` → BUILD SUCCEEDED。アプリ起動 (4秒生存) を確認。

| 設計書ID | 状況 |
|---|---|
| UT-006 表紙独立 | 実装・合格 (spine先頭/本文数不変) |
| UT-008 回転 | **未実装** (Phase 3) ※元ファイル不変のみ合格 |
| UT-009 特殊文字 | 合格 (XMLDocumentで復元一致、制御文字は拒否) |
| UT-010 BCP47/UUID | 合格 (構文のみ。サブタグレジストリ照合なし) |
| UT-015 manifest↔ZIP | 合格 |
| UT-016 mimetype | 合格 (生バイト直読み + 改竄・順序違反の否定テスト + 独立ツール `unzip -t`) |
| UT-017 nav/spine/layout | 合格 (ltr/rtl) |
| UT-018 EPUBCheck JSON | **偽ランナー(シェルスクリプト)でのみ合格**。実EPUBCheckのJSONでは未検証 |
| IT-008 キャンセル | 生成コア単体で合格 (部分EPUBなし)。UI/ExportUseCase経由は未実装 |
| IT-010 検証器起動失敗 | ランナー単体で合格 (`.unavailable`、合格にならない) |
| 元画像不変 | SHA-256/mtime/ディレクトリ内容の前後比較で合格 (生成コアのみ) |
| その他 UT/IT | Phase 1以降。未着手 |

## 未検証・未解決 (「完了」と扱わないこと)
1. **EPUBCheck未実行**。この環境にJavaが無い (`/usr/bin/java` はスタブ)。JRE/JARの取得は未実施 (ダウンロード許可待ち)。
   - 完了条件「EPUBCheckで1ページサンプルが妥当」は**未達**。
   - `EPUBCheckReportParser` のJSONスキーマは記憶ベースの暫定。実バージョンの出力で確定が必要。
   - OPFの `rendition` prefix省略 (ADR-011b) の影響も未確認。
2. **Java同梱・署名・Sandbox内起動・再配布ライセンス** (設計書 §10.2): 未検証。
3. **ZIPFoundation評価**: 未実施 (ADR-011)。自前ライターの他リーダー互換はEPUBCheck/Booksで要確認。
4. **Apple Books実機表示**: 未確認 (表紙/RTL/縦横混在)。
5. **アプリアイコン**: 未登録。参照画像は背景付きプレゼン画像であり、本番マスター化(1024px・余白・アルファ調整)が必要。
6. **Bundle ID**: 仮 `com.example.PageMint`。所有者確定待ち。DEVELOPMENT_TEAM は既存テンプレートの値を維持。
7. Xcodeの `PageMintTests` / UIテストターゲット、CI、license notice: 未作成。テストは現状SwiftPM側のみ。
8. サイズ実測・容量調整・画像最適化・取り込み・プロジェクト永続化: Phase 1〜3。
9. `Issue`/`EPUBBuilder.modifiedAt` 等の公開API形状はPhase 1で変わり得る。

## レビュー依頼ポイント (§16)
- P0観点: `EPUBArchiveWriter` が書き込むのは `destination` のみ。`EPUBBuilder` の失敗/キャンセル時に `abort()` で削除。ソース画像は読み取りのみ。
- `addStoredFile` はCRC算出と書き込みの2パス読み。読取中の変更は `sourceChangedDuringRead` で検出するが、その場合 `abort()` 経由でファイルを削除しているか (builderのcatch)。
- `EPUBCheckReportParser`: 食い違いを `.unavailable` に倒す設計が妥当か。EPUBCheckの終了コード仕様 (0/1以外=異常) の前提が正しいか。
- ZIPインスペクタ自体の網羅性 (ZIP64・コメント付きEOCD・不正オフセット) は限定的。

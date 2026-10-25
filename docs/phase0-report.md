# Phase 0 レポート (実装担当 → レビュー担当)

日付: 2026-10-25 / ブランチ: `phase0-spike` / 設計書: PageMint_Detailed_Design_v1.0 §15

## 構成
- `Pagemint.xcodeproj` … macOS専用 (deployment 15.0, Swift 6, App Sandbox + user-selected read-write, ネットワーク無効, Hardened Runtime)。ローカルSwiftPackage `PageMintCore` をリンク。
- `PageMintCore/` … Swift Package (生成コア)。`swift test` で単体実行可能。
  - `EPUBArchiveWriter` / `EPUBArchiveInspector` / `EPUBXMLSerializer` / `BookMetadataValidator` / `EPUBBuilder` / `ProcessEPUBCheckRunner` + `EPUBCheckReportParser`
  - `pagemint-spike` CLI: `swift run pagemint-spike out.epub 5 --cover --rtl`
- 設計書のフォルダ案 `PageMintApp/` ではなく、既存テンプレートの `Pagemint/` をそのまま使用 (同期グループ)。

## 実行したテスト (すべて実行済み)
`cd PageMintCore && swift test` → **46テスト / 5スイート合格** (macOS 27 / Xcode 27.1 / Swift 6.4)。
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
| UT-018 EPUBCheck JSON | 偽ランナー + **実EPUBCheck 5.4.0のJSON/実プロセス**で合格 |
| IT-008 キャンセル | 生成コア単体で合格 (部分EPUBなし)。UI/ExportUseCase経由は未実装 |
| IT-010 検証器起動失敗 | ランナー単体で合格 (`.unavailable`、合格にならない) |
| 元画像不変 | SHA-256/mtime/ディレクトリ内容の前後比較で合格 (生成コアのみ) |
| その他 UT/IT | Phase 1以降。未着手 |

## EPUBCheck / JRE スパイク結果 (2026-10-25 追記・実施済み)
取得物 (リポジトリには**コミットしていない**。`.gitignore` 済み):
- EPUBCheck 5.4.0: github.com/w3c/epubcheck/releases/download/v5.4.0/epubcheck-5.4.0.zip, 33,093,170 byte, SHA-256 `33350c61038e71dfb3d45a76aed04bf5481e6d5500cb780f6e98db8bbd15a28c` (公式チェックサム未公表のため自己計測値)
- Temurin JRE 21.0.13+9 aarch64 mac: adoptium/temurin21-binaries, 47,935,740 byte, SHA-256 `225bab0a...ec09a` (Adoptium APIの値と一致)

結果:
- スパイクCLI生成EPUB 4構成 (1枚 / 1枚+表紙 / 5枚+表紙 / 4枚+表紙+rtl) → **EPUBCheck 5.4.0 で 致命0・エラー0・警告0・情報0**。
- `rendition` prefix省略 (ADR-011b) は**問題なし**を確認 (警告0)。
- nav.xhtml を削除した壊れEPUB → exit 1, `RSC-001` ERROR 1件。実JSONをフィクスチャ化 (`docs/test-fixtures/epubcheck-5.4.0/`)。`line` は不明時 -1 で返るためパーサでnil扱い。JSONキー (`checker.checkerVersion/nError/nFatal`, `messages[].ID/severity/message/locations[].path`) は実出力と一致。
- `ProcessEPUBCheckRunner` の実ランタイム end-to-end テスト (環境変数 `PAGEMINT_JAVA` / `PAGEMINT_EPUBCHECK_JAR` 指定時のみ実行) 合格。**未指定だとスキップされる**ため、CIではランタイム配置が必要。
- **Sandbox内起動**: Sandbox有効 (user-selected rw, ネットワーク無効) のDebugビルドのアプリが、`Resources/ValidationRuntime/` の同梱JRE+EPUBCheckを `Process` で起動し検証成功 (`passed errors=0 warnings=0`)。Sandbox拒否ログなし。

`swift test`: **46テスト合格** (実ランタイム指定あり)。

## 未検証・未解決 (「完了」と扱わないこと)
1. **Sandbox内起動の検証条件は限定的**: Debug / Apple Development署名 / Hardened Runtimeなし / JREはAdoptium署名のまま。**Release + Hardened Runtime + Developer ID署名 + Notarization + JREの再署名(JIT等のentitlements)** は未検証。Mac App Store適合も未検証。
2. **同梱サイズ**: ValidationRuntime は約185MB (JRE全体)。`jlink`での最小化は未実施。
3. **ライセンス**: EPUBCheck 5.4.0 の同梱READMEは 3-Clause BSD と記載 (設計書§10.2/§20の「MIT」とは不一致 → 設計書側の訂正が必要)。
   **ライセンス通知**: Temurin (GPLv2+Classpath Exception) と EPUBCheck依存JARの通知文書は未作成 (`docs/license-notices/` は空)。再配布条件の最終確認は未了。
4. **aarch64のみ**: x86_64 / Universal は未対応・未検証。
5. **ZIPFoundation評価**: 未実施 (ADR-011)。ただし自前ZIPはEPUBCheck 5.4.0と`unzip -t`で受理された。
6. **Apple Books実機表示**: 未確認 (表紙/RTL/縦横混在)。
7. **画像は合成PNG/JPEGのみ**。実画像(ICC/CMYK/巨大画像)・日本語ファイル名は未検証。
8. **アプリアイコン**: 未登録 (参照画像は背景付き。1024pxマスター化が必要)。
9. **Bundle ID**: `com.fumiakimogi.Pagemint` に確定 (2026-10-25)。
10. Xcodeの `PageMintTests`/UIテストターゲット、CI、ランタイム自動配置スクリプト: 未作成。
11. 画像最適化・容量調整・取り込み・永続化・UT-008(回転): Phase 1〜3。

## レビュー依頼ポイント (§16)
- P0観点: `EPUBArchiveWriter` が書き込むのは `destination` のみ。`EPUBBuilder` の失敗/キャンセル時に `abort()` で削除。ソース画像は読み取りのみ。
- `addStoredFile` はCRC算出と書き込みの2パス読み。読取中の変更は `sourceChangedDuringRead` で検出するが、その場合 `abort()` 経由でファイルを削除しているか (builderのcatch)。
- Sandbox内スパイクはDebug署名限定 (上記)。リリース署名条件でのレビューは別途。
- `EPUBCheckReportParser`: 食い違いを `.unavailable` に倒す設計が妥当か。EPUBCheckの終了コード仕様 (0/1以外=異常) の前提が正しいか。
- ZIPインスペクタ自体の網羅性 (ZIP64・コメント付きEOCD・不正オフセット) は限定的。

## レビュー指摘対応 (Codex Phase 0 レビュー: P1×1, P2×2)
| 指摘 | 対応 | 回帰テスト (修正前コードで失敗を確認済み) |
|---|---|---|
| P1 不完全JSONが合格になる | `checker.nError/nFatal` と `messages` を必須化。型不正・欠落・`nWarning`不一致・ID/severity欠落は `.unavailable` | `incompleteJSONIsNeverPass` (9パターン) |
| P2 画像処理中キャンセルが成功扱い | 2パス読取の各チャンクと `finish()` 前、生成後にも `Task.checkCancellation()` | `cancellationDuringImageReadLeavesNoEPUB` |
| P2 キャンセルで終了待ちが長引く | キャンセル時もSIGTERM→2秒後SIGKILL (timeoutと共通化。PID直接killをやめ `isRunning` 確認) | `cancellationKillsProcessIgnoringSIGTERM` |
| 補足: catch外の失敗経路 | writer初期化・生成後OCF検査を単一のcatch範囲に統合。init失敗時も `abort()`。**検査違反は成功で返さず `archiveNonCompliant` を投げて出力削除** (従来は検査結果を無視していた) | 既存+上記 |

## 追加スパイク: Release + Hardened Runtime + MAS相当署名 (2026-10-25)
- 構成: Releaseビルド (Hardened Runtime有効)。`ValidationRuntime/jre` にJRE `Contents/Home` の中身を直置き (bundle構造を避ける)。同梱Mach-O 46個を子プロセス用entitlements (`app-sandbox` + `inherit` + `cs.allow-jit`) で `--options runtime` 署名し直し、アプリ本体は `app-sandbox` + `user-selected.read-write` のみで署名。
- 結果: `codesign --verify --deep --strict` 合格。Sandbox内のアプリが同梱JRE+EPUBCheck 5.4.0を起動し `passed errors=0 warnings=0`、Sandbox拒否ログなし。
- **限界 (未検証のまま)**: 署名は Apple Development 証明書のみ。**Mac App Store配布用証明書でのパッケージ作成、App Store Connectの検証(Transporter等)、審査、Developer ID署名、Notarizationは未実施**。`allow-jit` がMAS審査で許容されるかも未確認。署名スクリプト化・ビルドへの組込みも未実施 (手動実行)。
- アプリ側の `ContentView.swift` の検証用パスは `jre/bin/java` に変更済み。
- 収益モデルは ADR-012 (買い切り・広告/IAPなし)。販売先 (MAS / Developer ID) は上記の未検証事項の結果待ち。

# ADR-011: 自前ZIPライター (EPUBArchiveWriter) を採用し、ZIPFoundationは未評価

- 状態: 暫定採用 (Phase 0)
- 関連: 設計書 ADR-004 / §9.3

## 決定
`EPUBArchiveWriter` (Compression.framework の生DEFLATE + 自前ヘッダ書き込み、約250行) を使う。

## 理由
- `mimetype` 先頭・Stored・extraなし・データディスクリプタなし、をヘッダ書き込みレベルで構造的に保証できる。
- 依存追加なし (SPM取得を伴うダウンロードをPhase 0で行っていない)。
- 画像は再圧縮せずStoredでストリーミング。

## 未評価・制約
- **ZIPFoundationでOCF要件が満たせるかは未検証** (設計書スパイク項目)。本ADRは「満たせない場合は差し替え」の判断を先取りしたものではなく、評価を省略した判断である。
- ZIP64非対応 (4GiB超・65535エントリ超は明示的に失敗)。設計上限 maxPages=2000 / 2GB目安の範囲では不要。
- 画像のDeflateは行わない (Stored固定)。
- 他ZIP実装との相互運用は `unzip -t` とEPUBCheck(未実行)で確認する方針。

## ADR-011b: OPFに `prefix="rendition:..."` を宣言しない
設計書§9.2の例は `prefix="rendition: http://www.idpf.org/vocab/rendition/#"` を宣言しているが、
`rendition` はEPUB 3の予約済みprefixであり宣言不要。再宣言は EPUBCheck が警告/情報を出す可能性があるため省略した。
EPUBCheck 5.4.0 で宣言なしのEPUBが エラー/警告0 で通ることを確認済み (宣言ありとの差分比較は未実施)。

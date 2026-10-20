# Phase 1 + Phase 2 — PowerShellコード登録とCUI進捗改善

> 2026-10-21 / 対象: Windows PowerShell 5.1。開発規約: [AGENTS.md](../AGENTS.md)。主計画: [DEVELOPMENT_PLAN.md](./DEVELOPMENT_PLAN.md)。

## 目的とスコープ

1. 提供済み `Convert-Manga-AVIF-Quality70-EPUB-Standalone.zip` の `Convert-Manga.ps1`、`Convert-Manga-Epub.ps1`、`Convert-Manga.bat` とユーザー向けREADMEをソースとしてリポジトリに登録する。第三者バイナリ `avifenc.exe` は**登録しない**。元版の `Find-OrInstall-Avifenc` の挙動は維持する。
2. 変換本体のアルゴリズム・出力名・60MiBの無変換境界・品質探索・70MiB目標・ZIP Store・原本保護を変えず、CUIに**全体進捗／巻名／工程／ページ単位のAVIF進捗**と**成功・スキップ・上限超過・失敗**の結果サマリーを追加する。
3. **今回はPhase 3の連続変換・待機ループは実装しない。** 旧BAT起動方法と終了時のウィンドウ待機動作を維持する。

## 表示契約

- 全体進捗: PowerShell標準の `Write-Progress`（ID 1）を利用し、`処理済み件数 / 全件数` と現在の出力巻名を表示。スキップ・エラーも「処理済み」に含める。0件の除算を起こさない。最後に `-Completed` で消す。
- 工程: `入力解析`、`CBZ原本コピー`、`EPUB読書順抽出`、`アーカイブ展開`、`画像確認`、`品質探索`、`AVIF全ページ変換`、`CBZ書き込み`、`CBZ検証` 等を処理前の1行ログとして表示。
- AVIF画像進捗: 既存 `Invoke-ParallelAvif` の実完了枚数を維持し、全体の子進捗（ID 2 / ParentId 1）として表示。品質探索と全ページ変換を区別。画像進捗はページ総数と同じとは限らない（元の非AVIF画像やキャッシュ済み代表画像があるため）。
- 終了結果: `成功`、`上限超過警告`、`スキップ`、`失敗` を区別。上限超過は出力ありの警告として集計し、成功と二重計数しない。全件合計は入力対象件数に一致する。
- 完了後はBATで従来どおりキー入力待ちして終了。次の漫画のCUI投入はPhase 3。
- ETAは表示しない。ログ変更で画像・外部エンコーダーの引数を変えない。

## テスト設計（Docs First → Red → Green）

- Windows CIでPowerShell 5.1のASTパーサーを使ってPS1構文エラーを検出、BAT/READMEの存在を確認。
- 進捗率の0件・中間・全件・範囲外の丸め、`Write-Progress` のID1と子ID2、完了通知をテスト。
- 工程ログが巻名と現在工程を表示することをテスト。
- 合成小型CBZをPowerShellで変換し、60MiB以下のCBZが**SHA-256同一**でコピーされること、原本不変とサマリーを確認（WinRAR/AVIFエンコーダー不要経路）。
- AVIF品質探索・RAR・EPUBなどは別途Windows実機で確認。CIの小型CBZ成功はそれらの動作保証ではない。

## 受け入れ条件

- [ ] 原版のPowerShell/BAT/READMEを第三者バイナリを除いて管理する。
- [ ] PowerShell構文チェック・進捗のユニットテスト・小型CBZスモークがWindowsで成功する。
- [ ] 巻進捗、工程、AVIF画像進捗、終了集計が意図どおり表示される。
- [ ] 容量判定・品質探索・命名・ページ順・原本保護を変更しない。
- [ ] 最新コミットの `quality` 成功を確認し、未検証範囲を記載する。

**非対象:** Phase 3のコンソール再投入、Rust/Tauri移植、新GUI、新機能、外部バイナリのコミット。
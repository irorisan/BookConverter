# DOCS — BookConverter

BookConverterの仕様・開発資料の入口です。

## 現行方針（2026-10-21更新）

**既存のPowerShell + BATのCUIを維持し、進捗・処理状況・結果サマリーの見やすさを改善する。**

- PowerShellでファイル判定・命名・変換・進捗表示を実装する。
- 引き続き `avifenc` / `dwebp` と既存のアーカイブ展開方法を利用する。
- BATへのファイル/フォルダのドラッグ＆ドロップを維持する。**漫画は `Convert-Manga.bat`（作品名を一括入力）、雑誌・単巻は `Convert-Manga-Magazine.bat`（元名を維持）**を使う。巻数の有無で漫画・雑誌を自動振り分けしない。
- **変換完了後もCUIは開いたまま**。次の漫画を同じコンソールにドロップ（対応ホストのみ）またはパスを貼り付け、Enterで確定すると**別作品の新しいバッチ**を開始する。シリーズ名・進捗・集計は毎回リセットし、`q` / `exit`で終了する。
- コンソールへのファイルドロップの可否はWindows Terminal / Console Hostで実機確認する。非対応時もパス貼り付けで繰り返し利用できる。
- 無骨で実用的なコンソール表示を優先。**Rust/Tauri/Reactへの移植と豪華なGUI・EXE化は現在の計画から除外**する。
- 変換結果・原本保護・容量判定・品質探索・命名仕様は勝手に変更しない。

## 資料

- [開発・改修計画](./DEVELOPMENT_PLAN.md) — 現在の正本。決定事項、既存仕様、CUIの要求、工程、テスト・CI、受け入れ条件。
- [漫画・雑誌の入口分離](./MODE_SEPARATION.md) — BATの使い分け、巻数不明の漫画の出力名、回帰テスト条件。
- [Phase 1/2 — コード取り込み・進捗表示](./PHASE1_2_PROGRESS.md) — PowerShellソースのGit管理、工程/進捗表示、Windowsのテスト・受け入れ条件。
- [Phase 0 — 現行ツールの動作基準化](./PHASE0_BASELINE.md) — 静的に確認した仕様、合成フィクスチャとWindows実機の未確認事項。
- [AGENTS.md](../AGENTS.md) — Docs First、TDD、最小実装・KISS、最終整合性、PRとCIのルール。

## 現在の状態

**Phase 1・2はPR #5でマージ済み。Phase 3・4は連続変換と検証を追加**。元のソースは2026-10-20提供のスタンドアロンZIPを基準とし、`avifenc.exe`等の第三者バイナリは含まない。連続変換・検証の仕様と実機手順は [Phase 3・4](./PHASE3_4_CONTINUOUS.md) を参照。

PR内の`quality`は**Windows上でDOCS検証、合成入力テスト、PowerShell 5.1の構文/BOM/進捗/入力テスト、BAT連続変換、SHA-256、EPUB順序・自然順・命名・容量境界スモーク**を行う。WinRAR・avifenc・dwebpを使うE2E・実際の大量漫画・コンソールドロップ操作は自動テスト対象外で、別途Windows実機で確認する。

**元資料**: 2026-10-20提供の `Convert-Manga-AVIF-Quality70-EPUB-Standalone.zip` 内の `Convert-Manga.ps1`、`Convert-Manga-Epub.ps1`、`Convert-Manga.bat`、README。元の配布ZIP・第三者バイナリはリポジトリに追加していない。

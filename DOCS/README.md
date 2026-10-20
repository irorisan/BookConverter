# DOCS — BookConverter

BookConverterの仕様・開発資料の入口です。

## 現行方針（2026-10-21更新）

**既存のPowerShell + BATのCUIを維持し、進捗・処理状況・結果サマリーの見やすさを改善する。**

- PowerShellでファイル判定・命名・変換・進捗表示を実装する。
- 引き続き `avifenc` / `dwebp` と既存のアーカイブ展開方法を利用する。
- BATへのファイル/フォルダのドラッグ＆ドロップと作品名の一括入力を維持する。
- 無骨で実用的なコンソール表示を優先。**Rust/Tauri/Reactへの移植と豪華なGUI・EXE化は現在の計画から除外**する。
- 変換結果・原本保護・容量判定・品質探索・命名仕様は勝手に変更しない。

## 資料

- [開発・改修計画](./DEVELOPMENT_PLAN.md) — 現在の正本。決定事項、既存仕様、CUIの要求、工程、テスト・CI、受け入れ条件。
- [Phase 0 — 現行ツールの動作基準化](./PHASE0_BASELINE.md) — 静的に確認した仕様、合成フィクスチャとWindows実機の未確認事項。
- [AGENTS.md](../AGENTS.md) — Docs First、TDD、最小実装・KISS、最終整合性、PRとCIのルール。

## 現在の状態

現行PowerShellツールは**会話添付のスタンドアロンZIP**が基準。リポジトリには現時点で計画資料と合成CBZ/EPUBフィクスチャテストがあり、変換本体のPowerShellコードは**まだ登録されていない**。次段階でコードの置き場所とWindows実機での検証方法を整理する。

現在のGitHub Actions `quality` は、**DOCSの基本整合性とPython製の合成テスト入力を検証する暫定CI**。変換そのものやWindows CUIの正常動作を証明するものではない。PowerShell本体を追加した段階で、適切なWindows/Pester等のチェックを導入する。

**元資料**: 2026-10-20提供の `Convert-Manga-AVIF-Quality70-EPUB-Standalone.zip` 内の `Convert-Manga.ps1`、`Convert-Manga-Epub.ps1`、`Convert-Manga.bat`、README。元の配布ZIP・第三者バイナリはリポジトリに追加していない。

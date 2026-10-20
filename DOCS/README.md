# DOCS — BookConverter

BookConverter の設計・開発資料の入口です。

## 計画書

- [開発・移植計画](./DEVELOPMENT_PLAN.md) — 技術構成、現行PowerShell/BAT版の仕様、EPUB/AVIF/CBZ処理の移植方針、GUI、Rust構造、フェーズ、テスト・CI、リスク、受け入れ基準。

## 決定済み

- Tauri 2 + React + TypeScript + Tailwind CSS + shadcn/ui + Rust。
- Windows向けのモダンなデスクトップGUI。
- AVIFは当面 `avifenc`、WebPデコードは必要時に `dwebp`。libavif直接連携は後日の検討。
- 最終的にはPowerShell/BAT依存を廃止。
- 現行挙動の再現を先に行い、最適化は別途計測・判断。

## 現在の状態

**計画のみ**。Tauriアプリ本体とアプリ向けテスト・ビルドCIは未実装です。`quality` は現在 **DOCSの存在・基本形式・リンクだけを検証する暫定ワークフロー**です。アプリの動作やWindowsビルド成功を示すものではありません。Phase 1でテスト・ビルドチェックを拡張します。

**参照した元資料**: 2026-10-20提供の `Convert-Manga-AVIF-Quality70-EPUB-Standalone.zip` 内の `Convert-Manga.ps1` / `Convert-Manga-Epub.ps1` / `Convert-Manga.bat` / `README.md`（コード静的確認）。元の配布ZIPや同梱の第三者バイナリはこのリポジトリに追加していません。

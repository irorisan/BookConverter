# DOCS — BookConverter

BookConverter の設計・開発資料の入口です。

## 計画書

- [開発・移植計画](./DEVELOPMENT_PLAN.md) — 技術構成、現行PowerShell/BAT版の仕様、EPUB/AVIF/CBZ処理の移植方針、GUI、Rust構造、フェーズ、テスト・CI、リスク、受け入れ基準。
- [Phase 0 — 旧版の動作基準化](./PHASE0_BASELINE.md) — 合成CBZ/EPUB回帰ケース、厳密な60MiB境界、Windows実機の未実測事項と検証手順。

## 開発エージェント・実装ルール

- [AGENTS.md](../AGENTS.md) — 資料ファースト、TDD、KISS、後方互換・データ移行を行わない方針、最終確認、PR/CIの必須手順。
- アプリの合意済み仕様と実装順は[開発・移植計画](./DEVELOPMENT_PLAN.md)を参照。仕様変更時は先にドキュメントとテストを更新する。

## 決定済み

- Tauri 2 + React + TypeScript + Tailwind CSS + shadcn/ui + Rust。
- Windows向けのモダンなデスクトップGUI。
- AVIFは当面 `avifenc`、WebPデコードは必要時に `dwebp`。libavif直接連携は後日の検討。
- 最終的にはPowerShell/BAT依存を廃止。
- 現行挙動の再現を先に行い、最適化は別途計測・判断。

## 現在の状態

**Phase 0の静的基準と合成フィクスチャを準備**しています。Windows上で旧版の実変換・時間・画質を計測する作業は未実施です。Tauriアプリ本体とRust/Reactのテスト・ビルドCIも未実装です。現行の`quality`は**文書と合成フィクスチャの検査のみ**であり、変換処理やWindowsビルドの成功を意味しません。Phase 1でアプリ向け検査を追加します。

**参照した元資料**: 2026-10-20提供の `Convert-Manga-AVIF-Quality70-EPUB-Standalone.zip` 内の `Convert-Manga.ps1` / `Convert-Manga-Epub.ps1` / `Convert-Manga.bat` / `README.md`（コード静的確認）。元の配布ZIPや同梱の第三者バイナリはこのリポジトリに追加していません。

# BookConverter

Windows向けの漫画・雑誌をCBZにまとめるツールです。起動直後に **1=AVIF（Enterで既定）、2=WebP（CPUのみ）** を選択します。AVIFは従来のGPU＋CPU Hybridで変換します。

## 使い方

- **漫画**：`Convert-Manga.bat` にドラッグ＆ドロップ。シリーズ名を一度入力し、巻数を整理します。
- **雑誌・単巻**：`Convert-Manga-Magazine.bat` にドラッグ＆ドロップ。元のファイル名を維持します。
- 対応入力：ZIP / CBZ / RAR / 画像フォルダ / 画像主体EPUB。複数同時投入も可能です。
- Windows Terminal上でPowerShell 7.6が起動します。終了後も次の作品を入力でき、`q` / `exit`で終了します。

## 動作条件

- Windows、**PowerShell 7.6**、Windows Terminal（`wt.exe`）。AVIFはAV1 NVENC対応のNVIDIA GPUが必要です。WebPはGPU不要です。
- `ffmpeg.exe`（`tools/` またはPATH）。WebP選択時は`libwebp`対応ビルドを使用します。AVIF選択時はNVENC対応ビルド、CPUエンコード用`avifenc.exe`、**CPU AVIF検証用`avifdec.exe`**（libavif公式版、必要時に自動取得）が必要です。AVIF選択でWebPを入力すると`dwebp.exe`も使います。RAR展開にはWinRARが必要です。
- Hybridの既定は **GPU 12並列＋CPU 4並列**。品質探索はGPU主体（CPU代表ページ校正）で、自動調整します。

## 保存ルール

- AVIFは60MiB以下のCBZをそのままコピーし、60MiB超では必要に応じて変換します。WebPは60MiB以下や既存AVIFもCPUでWebPへ変換します。両方式とも完成CBZを**70MiB以下**に収め、収まらなければ保存しません。
- 出力先は入力元の親フォルダの`avif変換cbz/`または`webp変換cbz/`です。**原本・既存の同名出力は削除・上書きしません。** 詳細は[画像形式仕様](DOCS/ENCODING_FORMAT.md)。

## その他

- `MangaSplit.bat`は別機能の**見開き裁断ツール**です。詳しくは[見開き裁断仕様](DOCS/MANGA_SPLIT.md)。
- 更新は`Update-BookConverter.bat`から実行できます。旧BATの自動削除・移行処理はありません。構成変更時は再デプロイしてください。
- 詳細：[Hybrid変換仕様](DOCS/HYBRID_AVIF.md) / [開発計画](DOCS/DEVELOPMENT_PLAN.md)。

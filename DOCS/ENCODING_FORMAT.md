# 起動時の画像形式選択

すべての変換BATは、パス解析・作品名入力より先に1回だけ形式を尋ねる。
`1` / Enter / EOFはAVIF（既定）、`2`はWebP。不正な値は再入力。
選択は次バッチにも保持する。自動実行は `-EncodingFormat AVIF|WebP` で省略可能。
AVIFは既存のGPU＋CPU Hybrid方式、60MiB判定、品質、検証を維持する。
漫画・雑誌の2つのBATとも1を選ぶと従来のHybrid処理を使う。

WebPは両BATともCPUのみ。既存のFFmpegを
`tools/ffmpeg.exe`、ルート、PATHから探し、`libwebp` encoderを確認する。
NVENCは検査も実行もしない。FFmpegがなければ配置先を表示して失敗し、自動取得しない。
`libwebp` / lossy / compression_level 6 / threads 1 / 静止画1フレームで変換する。
WebPのQはAVIFと同等画質を意味しない。

互換性確認のためWebPは60MiB以下でも全ページを変換し、既存AVIF・WebP・GIF・BMPも
対象とする。アニメーションは最初の1フレームのみ。既存のAVIF出力は変更しない。
保存先は `webp変換cbz`、内部拡張子は `.webp`。元ページ順と命名規則を維持し、
拡張子変更による同名衝突は保存前に拒否する。両形式の出力フォルダは再走査から除外する。

既存の代表最大12ページ・最大5回・Q30〜95の探索、68MiB目標、70MiB上限、
最大3回の容量再調整とサンプル再利用を共用する。WebPも完成CBZが70MiBを
超過する場合は保存しない。CPU並列数は既存の `-CpuWorkers`（既定4、1〜4）を使う。
全生成WebPのRIFF/WEBPヘッダーと長さを
検査し、最終保存前に全ページをCPUデコード検証する。失敗・タイムアウト・キャンセル時は
CBZを確定せず子プロセスと一時領域を片付ける。原本・既存出力は上書きしない。

## 受け入れ・検証

- 初回1/Enter/EOF/2、不正値の再入力、選択後の連続バッチをテストする。
- WebP選択でGPU処理を呼ばず、CPU引数とWebP出力名になる。
- 合成画像・EPUBで順序、60MiB以下の変換、サンプル再利用、保存先分離、原本保護を検査。
- 既存AVIFの回帰テストを維持。実FFmpegがある場合は合成画像のWebP変換・デコードを検証。
- `quality` はテスト専用のimageio-ffmpeg 0.6.0を導入し、実FFmpegで合成画像を検証する。
  このバイナリを製品に同梱せず、製品の実行時依存にPythonを追加しない。
- WinRAR/RAR、NVENC実機、Kavita/Mihon/Komicでの実巻表示は別途手動検証が必要。
- 添付4ログはHybrid / Successだが、閲覧アプリでの互換性の証拠ではない。

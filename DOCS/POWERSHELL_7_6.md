# PowerShell 7.6への正式移行（2026-10-22）

## 実行環境・起動

製品・開発・CIの対象は **Windows版PowerShell 7.6.x / .NET 10**。
Windows標準のPowerShell 5.1および他の7.x系列の互換維持は行わない。
[MicrosoftのWindows導入手順](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows?view=powershell-7.6) に従い7.6.xを導入し、`pwsh.exe` をPATHへ登録する。
`pwsh -NoProfile -Command '$PSVersionTable.PSVersion; [Environment]::Version'` で7.6.x / 10.xを確認する。
PowerShellの通常配布には.NETランタイムが含まれ、SDKは製品の依存にしない。
全起動BATは `pwsh.exe`、ベンチマークの子プロセスは同じ `$PSHOME` の `pwsh.exe` を使用する。
直接実行する製品スクリプトでも7.6.x / Windowsを確認し、他環境では処理を開始しない。

## 維持する製品契約

AVIF変換、GPU12＋CPU4、品質探索・キャッシュ、最終サンプルデコード検証、
WebP処理、失敗・キャンセル・タイムアウト、70MiB拒否、CBZ件数・順序・サイズ検査、
ZIP Store / CRC32 / ZIP64 / UTF-8名、EPUBの安全な抽出、原本・既存出力保護は変更しない。
PR #21は移行開始時点ですでにmainへマージ済みのため、そのサンプル検証を基準とする。
移行PRによるマージ操作は行わない。

## 文字コード・C# ZIP

PS1はUTF-8（BOM任意）。BOM必須という5.1用制約を撤去し、厳密なUTF-8デコードと
日本語・空白を含むパスの回帰検査を行う。コンソール入出力は引き続きUTF-8を明示する。
PowerShell 7の `-Encoding UTF8` はBOMなし。JSONはUTF-8として読み書きする。
[文字コード仕様](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_character_encoding?view=powershell-7.6)
と [7.6 / .NET 10](https://devblogs.microsoft.com/powershell/announcing-powershell-7-6/) を参照。
製品の `Add-Type -TypeDefinition` によるC# ZIPライターは残し、.NET 10上でコンパイルと
ZIP64の65,535件・日本語名・ペイロード・上書き拒否を実行検査する。
ZIPライターを別実装へ置き換えることは移行の範囲に含めない。

## テスト変更・受け入れ条件

削除するのは `Add-Type -OutputType ConsoleApplication` による疑似FFmpeg / エンコーダー
生成と、それを実行しないと成立しないテストだけ。新しい模擬EXE生成方式は導入しない。
削除対象はGPUバッチの実プロセス分割・失敗伝播、旧GPUの9/12ページ模擬変換、
Hybridの250ページ並列実行・フォールバック・CPU再試行・WebP引き渡し・キャンセル・
タイムアウト・品質探索/キャッシュ統合・模擬変換CBZ・容量拒否の実プロセス検査。
これらの製品機能は残すが、このPRの自動テストでは実動作未検証になる。

疑似EXEに依存しない品質マッピング・エンコード/デコード引数・構文・BAT検査、
サンプル抽出の243枚・先頭/末尾・GPU/CPU代表・重複排除・既存AVIF、
品質探索と最終検証の接続検査は残す。進捗・入力・ZIP64・合成素材・BAT連続処理・
SHA-256・EPUB/spine・自然順・命名・60/70MiB境界・更新ツールの回帰も維持する。

CIはPowerShell **7.6.5** の公式Windows x64 ZIPを明示的にダウンロードし、
公開SHA-256を照合して専用ディレクトリへ展開する。PATH追加後、全テスト前に
7.6.5 / Core / Windows / .NET 10と実行パスを検証する。runner既定版には依存しない。
最新HEADの `quality` 成功を必須とし、実NVENC・avifenc・dwebp・WinRARのE2E、
実機の速度・画質・コンソールドロップは別途実機確認する。

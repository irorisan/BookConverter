# Phase 0 — 旧変換ツールの動作基準化

> 作成日: 2026-10-20 / 状態: **静的仕様確認済み・Windows実機実行は未確認**  
> 対象原本: 会話添付 `Convert-Manga-AVIF-Quality70-EPUB-Standalone.zip`  
> 参照: [開発・移植計画](./DEVELOPMENT_PLAN.md)  
> 次段階: Phase 1（Tauri / React / Rustの雛形とアプリ用CI）

## 1. 目的と範囲

Rust移植時に「正解」を判断できるよう、元のPowerShellスクリプト（`Convert-Manga.ps1`、`Convert-Manga-Epub.ps1`、`Convert-Manga.bat`）の入力・出力・失敗・境界値を固定する。**旧コードそのものの互換を維持する目的ではない**。合意済みの変換結果をゴールデン仕様として採用し、問題がある挙動はDocs Firstで仕様を変更してテストを更新する。

**Phase 0の到達条件**:

- [x] 静的コードとREADMEの主要処理を照合し、期待動作をケース化する。
- [x] 第三者作品を含まない再生成可能な合成データを用意する。
- [x] 自動テストでフィクスチャの構造・内容・順序を検証する。
- [ ] Windows PowerShell 5.1実機で旧スクリプトを実行し、ログ/出力と予想を照合する。
- [ ] AVIF品質選択の時間・出力容量を計測しベースライン値を記録する。
- [ ] WinRAR、`avifenc`、`dwebp`を含む依存環境を記録する。

Windows実機での未確認事項が残っているため、**実測ベースラインが確立したとは報告しない**。実際の変換処理の正常動作・Kavitaでの描画も未確認。

## 2. 静的解析から確認した重要な動作

| 条件 | ソースに基づく期待結果 |
|---|---|
| `60MiB` 以下のCBZ | `avif変換cbz/名称.cbz` へ**バイト列そのままコピー**（画像の解析・書き換えなし） |
| `60MiB` 以下のZIP/RAR/EPUB/画像フォルダ | 画像を順序づけし無再圧縮でCBZ（EPUBのみspine順の連番） |
| `60MiB` より1バイト大 | JPEG/PNG/WebPがあれば品質探索（最大12枚×5回）後にAVIF化。GIF/BMP/AVIFは保持 |
| 完成上限 | 70MiB以内を**目指す**。超えた場合は全体最大3試行、達成できない場合は最小結果を警告付きで保存 |
| シリーズ巻 | `v01`, `v100`、末尾`b/B`のみ削除、`a`は残す。複数シリーズが一括なら現行版は同じタイトルを1回聞いて適用する |
| 雑誌/単巻 | 巻数認識がなければ元のベース名のまま `名前.cbz`。日付 `2026-10-20` を巻数として認識しない |
| EPUB | container→OPF→spine→XHTML/SVG内の画像参照順。spineに含まれない表紙は先頭へ1度だけ。部分的な結果は残さずエラー |
| 画像名 | 通常アーカイブ/フォルダは自然順、EPUBは `001` からの連番。重複したCBZエントリ名は失敗 |
| 保存場所 | **入力ファイル（または巻フォルダ）の親**に `avif変換cbz/` を作成。既存同名はスキップし元入力を保持 |
| 並列設定 | 自動は `max(1, min(8, floor(論理CPU/2)))`、手動1〜16、`avifenc -s 6 -j 1` |

※ これは**コード静的確認結果**であり、実際にWindowsで再現されたことを意味しない。CBZ StoreのZIP内部の時間情報や正確な圧縮バイト列は正解判定に使用しない。

## 3. 合成フィクスチャ

第三者の漫画画像やEPUBは含めず、**小さな1px PNGとEPUBのXMLをPython標準ライブラリで生成**する。生成物は `tests/baseline/_generated/` （Gitに含めない）へ保存。フィクスチャ生成はテスト用の開発作業であり、製品本体にPython依存を加えない。

| ID | 入力 | 期待する分類と出力（同じシリーズ名 `ONE PIECE` 入力想定） |
|---|---|---|
| `CBZ_SMALL` | `ONE PIECE v100.cbz` | シリーズ / `ONE PIECE v100.cbz`、60MiB以下の原本バイト一致 |
| `CBZ_SUFFIX_B` | `ONE PIECE v100b.cbz` | シリーズ / `ONE PIECE v100.cbz`、同時投入なら通常巻優先・枝番bはスキップ |
| `CBZ_SUFFIX_A` | `ONE PIECE v03a.cbz` | シリーズ / `ONE PIECE v03a.cbz` |
| `CBZ_FULLWIDTH` | `ONE PIECE（１５）.cbz` | シリーズ / `ONE PIECE v15.cbz` |
| `MAGAZINE` | `Weekly_Ascii_2026-10-20.cbz` | 単巻 / 同名CBZ。日付を巻と誤認しない |
| `IMAGE_FOLDER` | `単巻テスト/` に `1.png`,`2.png`,`10.png` | 単巻 / `単巻テスト.cbz`。自然順 `1,2,10` |
| `EPUB_SPINE` | `葬送のフリーレン（１） - 山田鐘人 & アベツカサ.epub` | EPUB / `葬送のフリーレン v01.cbz`、**spine指定順**を連番のPNGに変換 |
| `EPUB_COVER` | `cover-only.epub` | 単巻 / `cover-only.cbz`。本文にない表紙を先頭へ追加 |
| `EPUB_BAD_PATH` | `invalid-traversal.epub` | **失敗**。EPUBルート外 `../../outside.png` を拒否し完成CBZを残さない |
| `CBZ_EXACT_60M` | **要求時のみ**生成 `Threshold v01.cbz` | サイズが正確に `60 × 2^20` バイト。AVIF化せずバイトコピー |
| `CBZ_ABOVE_60M` | **要求時のみ**生成 `Threshold v02.cbz` | サイズが正確に `60 × 2^20 + 1` バイト。**再圧縮分岐**に入ることを確認（画像内容が巨大な合成ダミーで正常エンコード可能とは限らない） |

### 生成・静的検査（プラットフォーム共通）

```powershell
python tests/baseline/generate_fixtures.py --out tests/baseline/_generated
python -m unittest discover -s tests/baseline -p "test_*.py" -v
```

厳密な60MiB境界も必要な場合:

```powershell
python tests/baseline/generate_fixtures.py --out tests/baseline/_generated --large
```

`--large`は約120MiBを生成するため、標準のCIでは実行しない。生成物は削除して再生成できる（原本ではない）。

## 4. Windows実機スモークテスト（未実施）

1. 必要なバージョンを記録する：Windows版、PowerShell 5.1、WinRAR、`avifenc --version`（使用可能なら）、`dwebp -version`、論理CPU、ストレージの種類。
2. **原本ZIPは読み取り専用のコピーに展開**する。サンプルフォルダ/ZIP/EPUBの生成物だけをドラッグ＆ドロップする。シリーズ名として `ONE PIECE`、並列数はEnter（自動）を選択。
3. 1回目：小さいCBZ/EPUB/画像フォルダを個別または同じ作品の巻で試す。別作品を一括投入する場合はシリーズ名の一括適用に注意し、別バッチに分ける。
4. 出力CBZのファイル名、画像枚数、**ZIP内ページ順**、元画像のハッシュ、元データの変更なし、同名スキップを照合する。
5. EPUB読書順：`EPUB_SPINE` の出力は `001.png`,`002.png`。画像内容から**青→赤**の順を確認（元の画像名順では赤→青）。
6. EPUB表紙：`EPUB_COVER` の出力は `001.png`（表紙）→`002.png`（本文）。破損パスは失敗・未出力。
7. `CBZ_EXACT_60M` は**元CBZと出力CBZのSHA-256一致**。 `CBZ_ABOVE_60M` はAVIF分岐のログを確認（正常変換を要求しない）。
8. AVIF正常変換は別の**合法・十分に大きい画像主体の入力**で確認する。総時間、Q、完成MiB、成功/超過/失敗、並列数、CPUを記録。ライセンスのない実漫画はGitに登録しない。
9. 期待と実際に差異があれば、再現手順・ログ・影響と判断を記録する。**自動的に旧実装の不具合を「仕様」と認めない**。

### Windows実測記録テンプレート

| 項目 | 実測値 |
|---|---|
| 実行日・Windows / PowerShell | 未実施 |
| WinRAR / avifenc / dwebp | 未実施 |
| CPU論理コア・メモリ・ストレージ | 未実施 |
| 小型ケースの結果（OK/差異） | 未実施 |
| 60MiBちょうど / +1バイト | 未実施 |
| EPUB順序・表紙・パストラバーサル | 未実施 |
| AVIF変換1巻（入力/出力MiB、Q、時間、並列数） | 未実施 |
| 元ファイル保護・既存出力スキップ | 未実施 |
| 異常系と差異 | 未実施 |

## 5. 現行実装で注意すべき点

- **60MiB境界はファイルのサイズ**で判定（フォルダだけ画像バイト数合計）。EPUBは書籍ファイル全体のサイズ。
- 名前重複は**完成先パス**と**CBZ内のエントリ名**の両方で検出する。異なる階層に同名ページがある場合も危険。
- 超過しても保存する挙動（警告付き）に注意。新GUIは「成功」と混同しない独立状態にする。
- 現行WinRARの導入、AVIF外部実行ファイルの自動ダウンロードは、今後のTauri配布でそのまま流用せず、ライセンスとセキュリティの確認後に決める。
- EPUBは文字主体の書籍やDRM付きの読書に対応しない。テキストや画像が混在するケースは未対応・異常系として扱う。
- 移植先ではZip Slip、展開サイズ上限、キャンセル処理、パス予約などの堅牢化を検討し、**セキュリティ上の改善を後方互換性のために妨げない**。

## 6. Phase 1への引き継ぎ

- この資料と合成データの**期待値**をRust単体テスト/結合テストへ変換する。
- GUIを先に薄く構築し、ファイル選択、一覧、変換キューをRust command/eventと接続する。
- `quality` をDOCSだけでなくRust fmt/clippy/test、TypeScriptの型チェック、Lint、UIテスト、Windowsビルドまで拡張する。
- Windowsで未実測の項目は残存リスクとしてPRに残す。Phase 0の作業は静的基準とフィクスチャを完成させることまで。**Windowsでの実測結果はまだない**。

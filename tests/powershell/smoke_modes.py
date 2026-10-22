"""Windows PowerShell 7.6 acceptance tests for Hybrid manga/magazine entry modes.

BAT dispatch through WT is checked separately in test-terminal-launch.ps1.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from smoke_cbz import ROOT, sha256
from smoke_continuous import cbz


def run_bat(entry: str, data: str, *paths: Path) -> str:
    with tempfile.TemporaryDirectory(prefix="bookconv-modes-work-") as temp:
        env = dict(os.environ, TEMP=temp, TMP=temp)
        result = subprocess.run(
            ["pwsh.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(ROOT / "scripts" / "Convert-Manga.ps1"),
             *(["-Magazine"] if "Magazine" in entry else []), *map(str, paths)],
            input=data, capture_output=True, text=True, encoding="utf-8",
            errors="strict", timeout=120, check=False, env=env,
        )
        assert not list(Path(temp).glob("MangaCbz_*")), "Work directory remains"
    text = result.stdout + result.stderr
    assert result.returncode == 0, (entry, result.returncode, text)
    return text


def main() -> None:
    if os.name != "nt":
        raise SystemExit("Requires Windows PowerShell 7.6")
    with tempfile.TemporaryDirectory(prefix="bookconv-modes-") as temp:
        folder = Path(temp) / "日本語 空白"
        unnamed_a = cbz(folder / "星の話 外伝.cbz")
        unnamed_b = cbz(folder / "星の話 特装版.cbz")
        vol = cbz(folder / "星の話（１）.cbz")
        monthly = cbz(folder / "月刊誌 (15).cbz")
        weekly = cbz(folder / "Weekly_Ascii_2026-10-20.cbz")
        originals = {p: sha256(p) for p in (unnamed_a, unnamed_b, vol, monthly, weekly)}
        out = folder / "avif変換cbz"

        # Even when volume parsing fails, manga BAT asks for one shared name.
        text = run_bat("Convert-Manga.bat", "星の話\n\nq\n", unnamed_a, unnamed_b, vol)
        assert text.count("シリーズの出力作品名") == 1, text
        for path in ("星の話 - 星の話 外伝.cbz", "星の話 - 星の話 特装版.cbz", "星の話 v01.cbz"):
            assert (out / path).is_file(), (path, text)
        assert "成功: 3 / 上限超過: 0 / スキップ: 0 / 失敗: 0" in text, text
        assert all(sha256(p) == digest for p, digest in originals.items())
        assert sha256(out / "星の話 - 星の話 外伝.cbz") == originals[unnamed_a]

        # Website-flavored filenames ending in _10 are manga volumes, not
        # unnumbered standalone items. A chosen series name must apply to both
        # conventional v18 and _10 naming in the same batch.
        site10 = cbz(folder / "Manga-Zip.info_10.cbz")
        doro18 = cbz(folder / "ドロヘドロ v18.cbz")
        fullwidth03a = cbz(folder / "作品名_０３ａ.cbz")
        for p in (site10, doro18, fullwidth03a):
            originals[p] = sha256(p)
        text = run_bat(
            "Convert-Manga.bat", "ドロヘドロ\n\nq\n",
            site10, doro18, fullwidth03a,
        )
        assert text.count("シリーズの出力作品名") == 1, text
        assert "成功: 3 / 上限超過: 0 / スキップ: 0 / 失敗: 0" in text, text
        for p, expected_name in (
            (site10, "ドロヘドロ v10.cbz"),
            (doro18, "ドロヘドロ v18.cbz"),
            (fullwidth03a, "ドロヘドロ v03.cbz"),
        ):
            assert sha256(out / expected_name) == originals[p], (expected_name, text)

        # Manga batch normalization strips A/B split markers and trailing
        # download-site tags without touching the source archives.
        tagged_cases = [
            ("TagStory v05A [DL-Raw.Se].cbz", "統一名 v05.cbz"),
            ("TagStory v06B DL-Raw.Se.cbz", "統一名 v06.cbz"),
            ("TagStory 第07巻A - DL-Raw.Se.cbz", "統一名 v07.cbz"),
            ("TagStory 第08B巻 [DL-Raw.Se].cbz", "統一名 v08.cbz"),
            ("TagStory vol.09ａ【DL-Raw.Se】.cbz", "統一名 v09.cbz"),
            ("TagStory v10.DL-Raw.Se.cbz", "統一名 v10.cbz"),
        ]
        tagged = [(cbz(folder / name), expected) for name, expected in tagged_cases]
        before = {p: sha256(p) for p, _ in tagged}
        text = run_bat("Convert-Manga.bat", "統一名\n\nq\n", *(p for p, _ in tagged))
        assert "成功: 6 / 上限超過: 0 / スキップ: 0 / 失敗: 0" in text, text
        for source, expected in tagged:
            assert sha256(out / expected) == before[source], (source, expected, text)
            assert sha256(source) == before[source], source

        # Cutting/scanning annotations and trailing W markers are metadata,
        # not volume numbers. Bare volume names use the parent directory title.
        cutting_cases = [
            ("v27_裁断.cbz", "統一名 v27.cbz"),
            ("第25巻w_裁断.cbz", "統一名 v25.cbz"),
            ("TagStory 第26巻Ｗ-裁断.cbz", "統一名 v26.cbz"),
            ("TagStory vol.28W [裁断].cbz", "統一名 v28.cbz"),
            ("TagStory v29w [DL-Raw.Se] _裁断.cbz", "統一名 v29.cbz"),
            ("TagStory 第30巻w【裁断】 [DL-Raw.Se].cbz", "統一名 v30.cbz"),
            ("TagStory v31_裁断_DL-Raw.Se.cbz", "統一名 v31.cbz"),
        ]
        cutting = [(cbz(folder / name), expected) for name, expected in cutting_cases]
        before_cutting = {p: sha256(p) for p, _ in cutting}
        text = run_bat("Convert-Manga.bat", "統一名\n\nq\n", *(p for p, _ in cutting))
        assert "成功: 7 / 上限超過: 0 / スキップ: 0 / 失敗: 0" in text, text
        for source, expected in cutting:
            assert sha256(out / expected) == before_cutting[source], (source, expected, text)
            assert sha256(source) == before_cutting[source], source

        # An embedded word must survive; an unnumbered standalone keeps its
        # source-name identifier. Magazine mode must not strip the markers.
        embedded_cutting = cbz(folder / "裁断研究所 v32.cbz")
        without_volume = cbz(folder / "裁断研究所 あとがき_裁断.cbz")
        text = run_bat("Convert-Manga.bat", "\n\nq\n", embedded_cutting)
        assert (out / "裁断研究所 v32.cbz").is_file(), text
        text = run_bat("Convert-Manga.bat", "統一名\n\nq\n", without_volume)
        assert (out / "統一名 - 裁断研究所 あとがき_裁断.cbz").is_file(), text
        magazine_cutting = cbz(folder / "月刊誌 第33巻w_裁断.cbz")
        magazine_hash = sha256(magazine_cutting)
        text = run_bat("Convert-Manga-Magazine.bat", "\nq\n", magazine_cutting)
        assert sha256(out / magazine_cutting.name) == magazine_hash
        assert sha256(magazine_cutting) == magazine_hash

        # A/B-only differences now collide by design; only the output is
        # deduplicated. The two originals must remain unchanged.
        split_a = cbz(folder / "TagStory v12A.cbz")
        split_b = cbz(folder / "TagStory v12B.cbz")
        unchanged = {p: sha256(p) for p in (split_a, split_b)}
        text = run_bat("Convert-Manga.bat", "統一名\n\nq\n", split_a, split_b)
        assert "成功: 1 / 上限超過: 0 / スキップ: 1 / 失敗: 0" in text, text
        assert (out / "統一名 v12.cbz").is_file(), text
        assert all(sha256(p) == old for p, old in unchanged.items())

        # Embedded site-looking text is part of the title, not a trailing tag.
        embedded = cbz(folder / "DL-Raw.Se実験 v13.cbz")
        text = run_bat("Convert-Manga.bat", "\n\nq\n", embedded)
        assert (out / "DL-Raw.Se実験 v13.cbz").is_file(), text

        # The magazine BAT is unchanged even for tag- and suffix-like filenames.
        magazine_tag = cbz(folder / "月刊誌 v14A [DL-Raw.Se].cbz")
        digest = sha256(magazine_tag)
        text = run_bat("Convert-Manga-Magazine.bat", "\nq\n", magazine_tag)
        assert "シリーズの出力作品名" not in text, text
        assert sha256(out / magazine_tag.name) == digest

        # Magazine mode leaves _10 untouched and does not reinterpret it as v10.
        text = run_bat("Convert-Manga-Magazine.bat", "\nq\n", site10)
        assert "シリーズの出力作品名" not in text, text
        assert sha256(out / "Manga-Zip.info_10.cbz") == originals[site10], text

        # Dedicated magazine BAT never guesses volumes and never prompts a
        # common series title, even if a volume-looking token is present.
        text = run_bat("Convert-Manga-Magazine.bat", f'\n"{weekly}"\n\nq\n', monthly)
        assert "シリーズの出力作品名" not in text, text
        for src in (monthly, weekly):
            assert (out / src.name).is_file(), (src, text)
            assert sha256(out / src.name) == originals[src]
        assert text.count("成功: 1 / 上限超過: 0 / スキップ: 0 / 失敗: 0") == 2, text

        # No-argument startup stays in mode selected by the BAT.
        solo = cbz(folder / "番外編.cbz")
        b = sha256(solo)
        text = run_bat("Convert-Manga.bat", f'"{solo}"\n作品名X\n\nq\n')
        assert "シリーズの出力作品名" in text
        assert sha256(out / "作品名X - 番外編.cbz") == b
        assert sha256(solo) == b

        # Existing destinations never get overwritten.
        again = run_bat("Convert-Manga-Magazine.bat", "\nq\n", weekly)
        assert "スキップ: 1" in again
        assert sha256(out / weekly.name) == originals[weekly]
        assert all(sha256(p) == digest for p, digest in originals.items())
        assert not list(folder.rglob(".manga_*.tmp"))
    print("PASS: separate manga/magazine modes, underscore volume suffix, batches and original hashes")


if __name__ == "__main__":
    main()

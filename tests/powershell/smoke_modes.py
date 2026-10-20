"""Windows PowerShell 5.1 acceptance tests for explicit manga and magazine BATs."""
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
            ["cmd.exe", "/d", "/c", str(ROOT / entry), *map(str, paths)],
            input=data, capture_output=True, text=True, encoding="utf-8",
            errors="strict", timeout=120, check=False, env=env,
        )
        assert not list(Path(temp).glob("MangaCbz_*")), "Work directory remains"
    text = result.stdout + result.stderr
    assert result.returncode == 0, (entry, result.returncode, text)
    return text


def main() -> None:
    if os.name != "nt":
        raise SystemExit("Requires Windows PowerShell 5.1")
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
    print("PASS: distinct manga/magazine BATs, unknown volumes, continuous batches, hashes")


if __name__ == "__main__":
    main()

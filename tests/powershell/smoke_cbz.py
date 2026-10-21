"""Windows smoke: one real below-60MiB CBZ is copied, never re-encoded."""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "baseline"))
from generate_fixtures import COLORS, png  # noqa: E402


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    if os.name != "nt":
        raise SystemExit("Smoke requires Windows powershell.exe")
    with tempfile.TemporaryDirectory(prefix="bookconv-") as directory:
        root = Path(directory)
        source = root / "日本語の漫画 v01.cbz"
        with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_STORED) as archive:
            archive.writestr("001.png", png(COLORS["red"]))
        before = sha256(source)
        # Two empty responses: accepted series name, and automatic workers.
        result = subprocess.run(
            ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(ROOT / "scripts" / "Convert-Manga.ps1"), str(source)],
            input="\n\nq\n", capture_output=True, text=True, encoding="utf-8",
            errors="replace", timeout=120, check=False,
        )
        output = root / "avif変換cbz" / "日本語の漫画 v01.cbz"
        if result.returncode != 0:
            raise AssertionError(f"Exit code {result.returncode}\n{result.stdout}\n{result.stderr}")
        if not output.is_file():
            raise AssertionError(f"Missing output\n{result.stdout}\n{result.stderr}")
        assert sha256(output) == before, "CBZ original bytes changed"
        assert sha256(source) == before, "CBZ input modified"
        assert "[工程]" in result.stdout, "No stage status in console"
        assert "成功: 1" in result.stdout, "No success in summary"
        assert "上限超過: 0" in result.stdout, "No oversized count in summary"
        assert re.search(r"変換所要時間: \d{2}:\d{2}:\d{2}\.\d", result.stdout), "No elapsed time in summary"
        print("PASS: PowerShell CBZ smoke, SHA-256 retained")


if __name__ == "__main__":
    main()
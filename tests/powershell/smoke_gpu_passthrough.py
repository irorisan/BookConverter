"""Windows smoke: Hybrid conversion modes retain small CBZ data without needing FFmpeg.

The Hybrid Terminal BAT dispatch contract is checked separately in test-terminal-launch.ps1.
"""
from __future__ import annotations
import hashlib
import os
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main() -> None:
    if os.name != "nt":
        raise SystemExit("Requires Windows PowerShell 7.6")
    with tempfile.TemporaryDirectory(prefix="bookconv-gpu-passthrough-") as td:
        root = Path(td)
        for mode, source_name, stdin in (
            ("Manga", "作品 v01.cbz", "\nq\n"),
            ("Magazine", "月刊誌 (15).cbz", "q\n"),
        ):
            source = root / source_name
            with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_STORED) as z:
                z.writestr("001.png", b"tiny testing fixture")
            before = digest(source)
            result = subprocess.run(
                ["pwsh.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
                 "-File", str(ROOT / "scripts" / "Convert-Manga.ps1"),
                 *(["-Magazine"] if mode == "Magazine" else []), str(source)],
                input="1\n" + stdin, capture_output=True, text=True, encoding="utf-8",
                errors="replace", timeout=120, check=False,
            )
            assert result.returncode == 0, (mode, result.stdout, result.stderr)
            assert "GPUプリセット [1-4]" not in result.stdout, (mode, result.stdout)
            assert "Hybrid AVIF:" in result.stdout, (mode, result.stdout)
            output = root / "avif変換cbz" / source_name
            assert output.is_file(), (mode, result.stdout, result.stderr)
            assert digest(output) == before, "GPU BAT modified a small CBZ"
            assert digest(source) == before, "GPU BAT modified original"
        print("PASS: Hybrid manga/magazine conversion modes, passthrough and original preservation")

if __name__ == "__main__":
    main()

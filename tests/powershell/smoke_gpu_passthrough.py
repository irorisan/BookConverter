"""Windows smoke: GPU BAT entrypoints retain small CBZ data without needing FFmpeg."""
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
        for script, source_name, stdin in (
            ("Convert-Manga-GPU.bat", "作品 v01.cbz", "\nq\n"),
            ("Convert-Manga-Magazine-GPU.bat", "月刊誌 (15).cbz", "q\n"),
        ):
            source = root / source_name
            with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_STORED) as z:
                z.writestr("001.png", b"tiny testing fixture")
            before = digest(source)
            result = subprocess.run(
                ["cmd.exe", "/d", "/c", str(ROOT / script), str(source)],
                input=stdin, capture_output=True, text=True, encoding="utf-8",
                errors="replace", timeout=120, check=False,
            )
            assert result.returncode == 0, (script, result.stdout, result.stderr)
            assert "GPUプリセット [1-4]" not in result.stdout, (script, result.stdout)
            assert "GPU並列: 12プロセス × 1画像（固定）" in result.stdout, (script, result.stdout)
            output = root / "avif変換cbz" / source_name
            assert output.is_file(), (script, result.stdout, result.stderr)
            assert digest(output) == before, "GPU BAT modified a small CBZ"
            assert digest(source) == before, "GPU BAT modified original"
        print("PASS: GPU manga/magazine BAT passthrough and original preservation")

if __name__ == "__main__":
    main()

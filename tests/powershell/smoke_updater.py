"""Offline Windows PowerShell 5.1 smoke test for private main-branch updater."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEGACY = (
    "Install-Latest-GitHub-GPU-Test.bat",
    "Install-Latest-GitHub-GPU-Test.ps1",
    "Convert-Manga.ps1",
    "Convert-Manga-Epub.ps1",
    "GPU-Functions.ps1",
)


def run_updater(folder: Path, archive: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "powershell.exe", "-NoLogo", "-NoProfile",
            "-ExecutionPolicy", "Bypass", "-File",
            str(folder / "scripts" / "Update-BookConverter.ps1"),
            "-ArchivePath", str(archive),
        ],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=120, check=False,
    )


def main() -> None:
    if os.name != "nt":
        raise SystemExit("Requires Windows PowerShell 5.1")

    with tempfile.TemporaryDirectory(prefix="bookconv-updater-") as tmp:
        temp = Path(tmp)
        destination = temp / "BookConverter 日本語"
        destination.mkdir()
        (destination / "scripts").mkdir()
        (destination / "tools").mkdir()
        (destination / "tools" / "ffmpeg.exe").write_bytes(b"my ffmpeg binary")
        (destination / "tools" / "avifenc.exe").write_bytes(b"my avifenc binary")
        (destination / "my-notes.txt").write_text("leave this unchanged", encoding="utf-8")
        (destination / "README.md").write_text("OUTDATED", encoding="utf-8")
        for name in LEGACY:
            (destination / name).write_text("LEGACY", encoding="utf-8")
        shutil.copy2(
            ROOT / "scripts" / "Update-BookConverter.ps1",
            destination / "scripts" / "Update-BookConverter.ps1",
        )

        # A validation failure must occur before modifying any project files.
        corrupt = temp / "invalid-main.zip"
        with zipfile.ZipFile(corrupt, "w") as z:
            z.writestr("BookConverter-main/README.md", "invalid")
        invalid = run_updater(destination, corrupt)
        assert invalid.returncode != 0, (invalid.stdout, invalid.stderr)
        assert (destination / "README.md").read_text(encoding="utf-8") == "OUTDATED"
        assert (destination / "Install-Latest-GitHub-GPU-Test.bat").exists()

        fixture = temp / "main.zip"
        with zipfile.ZipFile(fixture, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for source in ROOT.rglob("*"):
                if not source.is_file():
                    continue
                relative = source.relative_to(ROOT)
                if ".git" in relative.parts or "tools" in relative.parts:
                    continue
                z.write(source, Path("BookConverter-main") / relative)

        result = run_updater(destination, fixture)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert (destination / "README.md").read_bytes() == (ROOT / "README.md").read_bytes()
        assert (destination / "scripts" / "Convert-Manga.ps1").is_file()
        assert (destination / "scripts" / "GPU-Functions.ps1").is_file()
        assert (destination / "Update-BookConverter.bat").is_file()
        assert (destination / "Convert-Manga-GPU.bat").is_file()
        assert (destination / "tools" / "ffmpeg.exe").read_bytes() == b"my ffmpeg binary"
        assert (destination / "tools" / "avifenc.exe").read_bytes() == b"my avifenc binary"
        assert (destination / "my-notes.txt").read_text(encoding="utf-8") == "leave this unchanged"
        assert all(not (destination / name).exists() for name in LEGACY), "Old installers / PS1 were retained"
        print("PASS: offline main updater, legacy cleanup, tools/data retention, invalid archive protection")


if __name__ == "__main__":
    main()

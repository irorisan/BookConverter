"""Manga and magazine must be selected by BAT, never inferred from a filename."""
from __future__ import annotations

import tempfile
from pathlib import Path

from smoke_cbz import sha256
from smoke_continuous import cbz, output, run


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="bookconv-mode-") as temp:
        root = Path(temp) / "日本語 空白 & 文字"
        first = cbz(root / "01_誤記タイトル.cbz")
        second = cbz(root / "02_別名の漫画.cbz")
        before = {p: sha256(p) for p in (first, second)}

        # Manga mode must NEVER silently treat files with no volume as magazines.
        # Even mismatched input titles get the same explicitly chosen series name.
        text = run("共通シリーズ\n\n1\n2\nq\n", first, second)
        assert "巻数" in text, text
        assert "成功: 2 / 上限超過: 0 / スキップ: 0 / 失敗: 0" in text, text
        assert sha256(output(first, "共通シリーズ v01.cbz")) == before[first]
        assert sha256(output(second, "共通シリーズ v02.cbz")) == before[second]
        assert not output(first).exists(), "Manga mode silently emitted a magazine title"
        assert not output(second).exists(), "Manga mode silently emitted a magazine title"

        # Invalid manual volume is not interpreted as executable input.
        skip = cbz(root / "未確定の本.cbz")
        digest = sha256(skip)
        text = run("\n\ninvalid\ns\nq\n", skip)
        assert "巻数" in text, text
        assert "成功: 0 / 上限超過: 0 / スキップ: 1 / 失敗: 0" in text, text
        assert not output(skip).exists(), "Unknown volume was silently auto-numbered"
        assert sha256(skip) == digest

        # Magazine mode never normalizes a volume-like suffix or asks series/volume.
        magazine = cbz(root / "週刊雑誌 v100b.cbz")
        one_shot = cbz(root / "特別号 2026-10-21.cbz")
        digests = {p: sha256(p) for p in (magazine, one_shot)}
        text = run("\nq\n", magazine, one_shot, bat="Convert-Magazine.bat")
        assert "成功: 2 / 上限超過: 0 / スキップ: 0 / 失敗: 0" in text, text
        assert "シリーズの出力作品名" not in text, text
        assert "巻数を入力" not in text, text
        for p in (magazine, one_shot):
            assert sha256(p) == digests[p] == sha256(output(p))
        assert not output(magazine, "週刊雑誌 v100.cbz").exists()

        # A second batch in the same magazine CUI retains its selected mode.
        later = cbz(root / "別冊 07.cbz")
        text = run(f'\n"{later}"\n\nq\n', magazine, bat="Convert-Magazine.bat")
        assert "スキップ: 1" in text, text
        assert sha256(output(later)) == sha256(later)

        # Manga series with detectable volumes still use the existing naming path.
        recognized = cbz(root / "作品名 v100b.cbz")
        text = run("\n\nq\n", recognized)
        assert "成功: 1" in text, text
        assert sha256(output(recognized, "作品名 v100.cbz")) == sha256(recognized)

        for p, digest in {**before, skip: sha256(skip), **digests}.items():
            assert sha256(p) == digest, f"Input was modified: {p}"
        assert not list(root.rglob(".manga_*.tmp"))
        print("PASS: separate Manga/Magazine BAT, manual volume, no false magazine, no overwrite")


if __name__ == "__main__":
    main()

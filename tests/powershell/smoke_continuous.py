"""Actual BAT + Windows PowerShell 7.6; synthetic inputs only, no encoders."""
from __future__ import annotations

import os
import subprocess
import tempfile
import zipfile
from pathlib import Path

from smoke_cbz import ROOT, sha256
from generate_fixtures import COLORS, png


def cbz(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as z:
        z.writestr("001.png", png(COLORS["red"]))
    return path


def run(lines: str, *args: Path, expected: int = 0, magazine: bool = False) -> str:
    with tempfile.TemporaryDirectory(prefix="bookconv-work-") as work:
        env = dict(os.environ, TEMP=work, TMP=work)
        result = subprocess.run(
            ["cmd.exe", "/d", "/c", str(ROOT / ("Convert-Manga-Magazine.bat" if magazine else "Convert-Manga.bat")), *map(str, args)],
            input=lines, capture_output=True, text=True, encoding="utf-8",
            errors="strict", timeout=120, check=False, env=env,
        )
        assert not list(Path(work).glob('MangaCbz_*')), (result.stdout, 'Work directory remains')
    assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
    return result.stdout + result.stderr


def output(source: Path, name: str | None = None) -> Path:
    return source.parent / "avif変換cbz" / (name or source.name)


def main() -> None:
    if os.name != "nt":
        raise SystemExit("Requires Windows PowerShell 7.6 and cmd.exe")
    with tempfile.TemporaryDirectory(prefix="bookconv-continuous-") as temp:
        folder = Path(temp) / "日本語 空白 & リテラル"
        first = cbz(folder / "まるまる漫画 v01.cbz")
        first2 = cbz(folder / "まるまる漫画 v02.cbz")
        second = cbz(folder / "さんかく漫画（３）.cbz")
        originals = {p: sha256(p) for p in (first, first2, second)}
        text = run(f'\n1\n"{second}"\n\n2\nq\n', first, first2)
        assert '成功: 2 / 上限超過: 0 / スキップ: 0 / 失敗: 0' in text, text
        assert '成功: 1 / 上限超過: 0 / スキップ: 0 / 失敗: 0' in text, text
        assert '[1/2] まるまる漫画 v01.cbz' in text, text
        assert '[1/1] さんかく漫画 v03.cbz' in text, text
        assert '元のシリーズ名: さんかく漫画' in text, text
        expected_outputs = [output(first), output(first2), output(second, 'さんかく漫画 v03.cbz')]
        for src, dst in zip(originals, expected_outputs):
            assert sha256(src) == originals[src]
            assert sha256(dst) == originals[src]
        existing = {p: sha256(p) for p in expected_outputs}

        # No BAT arguments: invalid/blank input, pasted multiple paths, existing outputs.
        unsupported = folder / '対象外.txt'
        unsupported.write_text('untouched', encoding='utf-8')
        text = run(f'\n"{folder / "missing.cbz"}"\n"{unsupported}"\n"unclosed\n"{first}" "{first2}"\n\n\nexit\n')
        assert 'スキップ: 2 / 失敗: 0' in text, text

        # Mixed failed and successful volumes, then a fresh series. No external tools.
        broken = folder / '失敗作品 v01.epub'
        broken.write_bytes(b'not an epub')
        good = cbz(folder / '回復作品 v07.cbz')
        fresh = cbz(folder / '再開作品 v01.cbz')
        originals.update({p: sha256(p) for p in (broken, good, fresh, unsupported)})
        text = run(f'"{broken}" "{good}"\n混在作品\n1\n"{fresh}"\n\n\nq\n')
        assert '成功: 1 / 上限超過: 0 / スキップ: 0 / 失敗: 1' in text, text
        assert '成功: 1 / 上限超過: 0 / スキップ: 0 / 失敗: 0' in text, text
        assert '[1/1] 再開作品 v01.cbz' in text, text
        assert not output(broken, '混在作品 v01.cbz').exists()
        assert sha256(output(good, '混在作品 v07.cbz')) == originals[good]
        assert sha256(output(fresh)) == originals[fresh]

        # Literal shell characters in a pasted path must never execute.
        literal = cbz(folder / '$(throw 1); 雑誌 & 特集.cbz')
        before = sha256(literal)
        text = run(f'"{literal}"\n\nq\n', magazine=True)
        assert sha256(literal) == before == sha256(output(literal)), text
        for p, digest in originals.items():
            assert sha256(p) == digest, f'Input modified: {p}'
        for p, digest in existing.items():
            assert sha256(p) == digest, f'Existing output modified: {p}'
        assert not list(folder.rglob('.manga_*.tmp')), 'Partial output remains'
        assert not list(folder.rglob('*.avif')), 'Unexpected encoding'
        run('q\n')
        run('exit\n')
        run('')  # EOF must not spin forever.
        print('PASS: real BAT, two series, reset, invalid input, recovery, skip, hashes, q/exit/EOF')


if __name__ == '__main__':
    main()

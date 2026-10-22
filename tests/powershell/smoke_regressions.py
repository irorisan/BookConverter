"""External-tool-free conversion regressions; these do not validate AVIF/RAR E2E."""
from __future__ import annotations

import tempfile
import zipfile
from pathlib import Path

from smoke_continuous import cbz, output, run
from smoke_cbz import sha256
from generate_fixtures import COLORS, MIB, epub, make_exact_size_cbz, png


def assert_pages(path: Path, names: list[str], payloads: list[bytes]) -> None:
    with zipfile.ZipFile(path) as z:
        assert z.namelist() == names, (path, z.namelist())
        assert [z.read(n) for n in names] == payloads
        assert all(e.compress_type == zipfile.ZIP_STORED for e in z.infolist())


def main() -> None:
    with tempfile.TemporaryDirectory(prefix='bookconv-regressions-') as temp:
        root = Path(temp)
        spine = root / 'spine.epub'
        cover = root / 'cover.epub'
        unsafe = root / 'traversal.epub'
        epub(spine)
        epub(cover, cover=True)
        epub(unsafe, bad_path=True)
        images = root / '単巻フォルダ'
        images.mkdir()
        colors = ['red', 'blue', 'green']
        for name, color in zip(['1.png', '2.png', '10.png'], colors):
            (images / name).write_bytes(png(COLORS[color]))
        hashes = {p: sha256(p) for p in root.rglob('*') if p.is_file()}
        text = run(f'"{spine}" "{cover}" "{unsafe}" "{images}"\n\nq\n', magazine=True, expected=1)
        assert '成功: 3 / 上限超過: 0 / スキップ: 0 / 失敗: 1' in text, text
        assert_pages(output(spine, 'spine.cbz'), ['001.png', '002.png'], [png(COLORS[c]) for c in ['blue', 'red']])
        assert_pages(output(cover, 'cover.cbz'), ['001.png', '002.png'], [png(COLORS[c]) for c in ['cover', 'green']])
        assert_pages(root / 'avif変換cbz' / '単巻フォルダ.cbz', ['1.png', '2.png', '10.png'], [png(COLORS[c]) for c in colors])
        assert not output(unsafe, 'traversal.cbz').exists()

        # Normalized both a/b suffixes and fullwidth volume digits.
        volumes = [cbz(root / n) for n in ['巻物 v100b.cbz', '巻物 v100.cbz', '巻物 v03a.cbz', '巻物（１５）.cbz']]
        text = run('\n\nq\n', *volumes)
        assert '成功: 3 / 上限超過: 0 / スキップ: 1 / 失敗: 0' in text, text
        for name in ['巻物 v100.cbz', '巻物 v03.cbz', '巻物 v15.cbz']:
            assert (root / 'avif変換cbz' / name).is_file()

        # Exact 60MiB uses a byte copy; no WinRAR/avifenc download is involved.
        boundary = root / '境界.cbz'
        make_exact_size_cbz(boundary, 60 * MIB)
        digest = sha256(boundary)
        text = run('\nq\n', boundary, magazine=True)
        assert 'CBZ原本コピー' in text, text
        assert sha256(boundary) == digest == sha256(output(boundary))

        # Hybrid never commits a >70MiB CBZ (including unchanged source AVIF).
        large = root / '大容量'
        large.mkdir()
        page = large / '001.avif'
        with page.open('wb') as stream:
            stream.truncate(70 * MIB + 1)
        digest = sha256(page)
        text = run('\nq\n', large, magazine=True, expected=1)
        assert '成功: 0 / 上限超過: 0 / スキップ: 0 / 失敗: 1' in text, text
        assert sha256(page) == digest, 'Uncompressed AVIF input changed'
        assert not (root / 'avif変換cbz' / '大容量.cbz').exists()
        for p, digest in hashes.items():
            assert sha256(p) == digest, p
        assert not list(root.rglob('.manga_*.tmp'))
        print('PASS: EPUB spine/cover/refusal, natural order, Store, naming, exact 60MiB, 70MiB refusal')


if __name__ == '__main__':
    main()

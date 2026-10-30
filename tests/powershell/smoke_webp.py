"""Real CPU FFmpeg: small inputs, AVIF decode, ordering, continuous batches and safety."""
from __future__ import annotations

import os
import json
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

from smoke_cbz import ROOT, sha256
from generate_fixtures import COLORS, png, epub


def main() -> None:
    ffmpeg = os.environ.get('BOOKCONVERTER_TEST_FFMPEG') or shutil.which('ffmpeg.exe')
    if not ffmpeg:
        import imageio_ffmpeg
        ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    with tempfile.TemporaryDirectory(prefix='bookconv-webp-') as td:
        root = Path(td)
        # Private PATH ensures the production finder discovers a real executable.
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        shutil.copy2(ffmpeg, bin_dir / 'ffmpeg.exe')
        for dll in Path(ffmpeg).parent.glob('*.dll'):
            shutil.copy2(dll, bin_dir / dll.name)
        work = root / 'work'
        work.mkdir()
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], TEMP=str(work), TMP=str(work))
        folder = root / '日本語 空白 v01'
        folder.mkdir()
        for name, color in [('1.png','red'), ('2.png','blue'), ('10.png','green')]:
            (folder / name).write_bytes(png(COLORS[color]))
        # Real AVIF, ensuring it is decoded rather than copied into the WebP CBZ.
        subprocess.run([ffmpeg, '-v','error','-i',str(folder/'1.png'), '-frames:v','1',str(folder/'11.avif')], check=True)
        # More than 12 pages exercises both sample reuse and the full-pass worker queue.
        for number in range(12, 25):
            (folder / f'{number}.png').write_bytes(png(COLORS['red']))
        book = root / '続き.epub'
        epub(book, cover=True)
        originals = {p: sha256(p) for p in root.rglob('*') if p.is_file() and p.parent != bin_dir}
        # Existing AVIF output must coexist and remain untouched.
        avif_output = root / 'avif変換cbz'
        avif_output.mkdir()
        (avif_output / '日本語 空白 v01.cbz').write_bytes(b'existing AVIF output')

        def run(lines: str, *paths: Path, extra: tuple[str,...] = (), expected: int = 0) -> str:
            result = subprocess.run(
                ['pwsh.exe','-NoLogo','-NoProfile','-File',str(ROOT/'scripts/Convert-Manga.ps1'),
                 '-Magazine', *extra, *map(str,paths)],
                input=lines, capture_output=True, text=True, encoding='utf-8', env=env, timeout=180,
            )
            assert result.returncode == expected, (result.stdout, result.stderr)
            assert not list(work.glob('MangaCbz_*')), result.stdout
            assert not list(root.rglob('.manga_*.tmp')), result.stdout
            return result.stdout + result.stderr

        text = run(f'invalid\n2\n"{book}"\nq\n', folder)
        assert text.startswith('エンコード形式を選択してください'), text
        assert text.count('エンコード形式を選択してください') == 1, text
        assert text.count('成功: 1 / 上限超過: 0 / スキップ: 0 / 失敗: 0') == 2, text
        assert 'WebP全ページデコード検証' in text and 'Hybrid AVIF:' not in text, text
        assert 'テスト画像再利用 12 枚' in text, text
        assert 'NVENC' not in text and 'avifenc.exe' not in text and 'dwebp.exe' not in text, text
        outputs = [root/'webp変換cbz'/'日本語 空白 v01.cbz', root/'webp変換cbz'/'続き.cbz']
        reports = [json.loads(p.read_text(encoding='utf-8-sig')) for p in (root/'webp変換cbz'/'metrics').glob('*.json')]
        assert len(reports) == 2
        for report in reports:
            assert report['Mode'] == 'WebP' and report['GpuWorkers'] == 0
            assert all(p['GpuPages'] == 0 for p in report['Passes'])
        names_by_output = [['1.webp','2.webp','10.webp','11.webp'] + [f'{n}.webp' for n in range(12,25)], ['001.webp','002.webp']]
        for output, names in zip(outputs, names_by_output):
            with zipfile.ZipFile(output) as z:
                assert z.namelist() == names, z.namelist()
                for i, name in enumerate(names):
                    data = z.read(name)
                    assert data[:4] == b'RIFF' and data[8:12] == b'WEBP'
                    page = root / f'verify{i}.webp'
                    page.write_bytes(data)
                    subprocess.run([ffmpeg,'-v','error','-xerror','-i',str(page),'-f','null','NUL'], check=True)
        assert (avif_output/'日本語 空白 v01.cbz').read_bytes() == b'existing AVIF output'
        for path, digest in originals.items():
            assert sha256(path) == digest, path
        digests = {p: sha256(p) for p in outputs}
        assert 'スキップ: 1' in run('2\nq\n', folder)
        assert all(sha256(p) == digest for p,digest in digests.items())
        assert 'スキップ: 2' in run('2\nq\n', root)

        cancelled = root/'cancelled'
        cancelled.mkdir()
        (cancelled/'1.png').write_bytes(png(COLORS['red']))
        cancel_file = root/'cancel.flag'
        cancel_file.touch()
        assert 'キャンセル' in run('2\nq\n', cancelled, extra=('-CancelFile',str(cancel_file)), expected=1)
        assert not (root/'webp変換cbz'/'cancelled.cbz').exists()

        collision = root/'collision'
        collision.mkdir()
        (collision/'1.png').write_bytes(png(COLORS['red']))
        shutil.copy2(folder/'11.avif', collision/'1.avif')
        assert '画像名が重複' in run('2\nq\n', collision, expected=1)
        assert not (root/'webp変換cbz'/'collision.cbz').exists()
        # Invalid image must fail without committing an output.
        bad = root/'broken'
        bad.mkdir()
        (bad/'1.png').write_bytes(b'not an image')
        assert '失敗: 1' in run('2\nq\n', bad, expected=1)
        assert not (root/'webp変換cbz'/'broken.cbz').exists()
        # Explicit format bypasses the menu and retains WebP CPU behavior.
        assert 'エンコード形式を選択' not in run('q\n', folder, extra=('-EncodingFormat','WebP'))
        print('PASS: real CPU WebP, AVIF input, small EPUB, page order, continuous batches, protection and failure cleanup')


if __name__ == '__main__':
    main()

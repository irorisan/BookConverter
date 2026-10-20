"""Build synthetic Phase 0 inputs. This is a test helper, not a runtime dependency."""
from __future__ import annotations

import argparse
import struct
import tempfile
import zlib
import zipfile
from pathlib import Path

MARKER = ".bookconverter-generated"
MIB = 1 << 20
COLORS = {
    "red": (240, 40, 40),
    "blue": (35, 65, 230),
    "green": (25, 175, 95),
    "cover": (245, 215, 50),
}


def png_chunk(tag: bytes, payload: bytes) -> bytes:
    data = tag + payload
    return struct.pack(">I", len(payload)) + data + struct.pack(">I", zlib.crc32(data) & 0xFFFFFFFF)


def png(rgb: tuple[int, int, int]) -> bytes:
    header = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    compressed = zlib.compress(b"\x00" + bytes(rgb), level=9)
    return (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
            + png_chunk(b"IDAT", compressed) + png_chunk(b"IEND", b""))


def zip_info(filename: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(filename=filename, date_time=(2020, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_STORED
    return info


def write_zip(path: Path, entries: list[tuple[str, bytes]]) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for name, contents in entries:
            archive.writestr(zip_info(name), contents)


def xhtml(image: str) -> str:
    return ('<?xml version="1.0" encoding="UTF-8"?>'
            f'<html xmlns="http://www.w3.org/1999/xhtml"><body>'
            f'<img src="{image}" /></body></html>')


def epub(path: Path, *, bad_path: bool = False, cover: bool = False) -> None:
    container = (
        b'<?xml version="1.0" encoding="UTF-8"?>'
        b'<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
        b'<rootfiles><rootfile full-path="OEBPS/content.opf" '
        b'media-type="application/oebps-package+xml"/></rootfiles></container>'
    )
    if bad_path:
        # The second .. ascends above the EPUB root from OEBPS/page.xhtml.
        items = ['<item id="p1" href="page.xhtml" media-type="application/xhtml+xml"/>']
        spine = ["p1"]
        pages = [("OEBPS/page.xhtml", xhtml("../../outside.png").encode())]
        images = []
    elif cover:
        items = [
            '<item id="p1" href="page.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="img" href="images/green.png" media-type="image/png"/>',
        ]
        spine = ["p1"]
        pages = [("OEBPS/page.xhtml", xhtml("images/green.png").encode())]
        images = [("OEBPS/images/green.png", png(COLORS["green"])),
                  ("OEBPS/images/cover.png", png(COLORS["cover"]))]
    else:
        items = [
            '<item id="p1" href="page1.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="p2" href="page2.xhtml" media-type="application/xhtml+xml"/>',
            '<item id="red" href="images/red.png" media-type="image/png"/>',
            '<item id="blue" href="images/blue.png" media-type="image/png"/>',
        ]
        # XML/reading order is blue, red; filenames/archive order are red, blue.
        spine = ["p2", "p1"]
        pages = [("OEBPS/page1.xhtml", xhtml("images/red.png").encode()),
                 ("OEBPS/page2.xhtml", xhtml("images/blue.png").encode())]
        images = [("OEBPS/images/red.png", png(COLORS["red"])),
                  ("OEBPS/images/blue.png", png(COLORS["blue"]))]

    cover_tag = ('<item id="cover" href="images/cover.png" '
                 'media-type="image/png" properties="cover-image"/>') if cover else ""
    manifest = "".join(items) + cover_tag
    spine_xml = "".join(f'<itemref idref="{item}"/>' for item in spine)
    opf_xml = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:identifier id="id">synthetic</dc:identifier></metadata>'
        f'<manifest>{manifest}</manifest><spine>{spine_xml}</spine></package>'
    )
    write_zip(path, [
        ("mimetype", b"application/epub+zip"),
        ("META-INF/container.xml", container),
        ("OEBPS/content.opf", opf_xml.encode("utf-8")),
        *pages,
        *images,
    ])


def make_exact_size_cbz(path: Path, target_size: int) -> None:
    """ZIP_STORED CBZ of exact size. Its padding.dat is NOT an image."""
    with tempfile.TemporaryDirectory() as directory:
        padding = Path(directory) / "padding.dat"
        padding.write_bytes(b"")

        def write() -> None:
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(zip_info("001.png"), png(COLORS["green"]))
                archive.write(padding, arcname="padding.dat", compress_type=zipfile.ZIP_STORED)

        write()
        remaining = target_size - path.stat().st_size
        if remaining < 0:
            raise ValueError("target_size too small")
        with padding.open("wb") as stream:
            stream.truncate(remaining)
        write()
        if path.stat().st_size != target_size:
            raise AssertionError(f"Exact ZIP size failed: {target_size} vs {path.stat().st_size}")


def generate(out: Path, *, large: bool = False) -> None:
    out = out.resolve()
    if out.exists() and not (out / MARKER).is_file():
        raise ValueError(f"Refusing to write into unmarked existing directory: {out}")
    out.mkdir(parents=True, exist_ok=True)
    (out / MARKER).write_text("Generated by tests/baseline/generate_fixtures.py\n", encoding="utf-8")

    manga = out / "manga"
    magazines = out / "magazines"
    epubs = out / "epubs"
    single = out / "single" / "単巻テスト"
    for directory in (manga, magazines, epubs, single):
        directory.mkdir(parents=True, exist_ok=True)

    page = [("001.png", png(COLORS["red"]))]
    for name in ("ONE PIECE v100.cbz", "ONE PIECE v100b.cbz",
                 "ONE PIECE v03a.cbz", "ONE PIECE（１５）.cbz"):
        write_zip(manga / name, page)
    write_zip(magazines / "Weekly_Ascii_2026-10-20.cbz", page)
    for name, color in (("1.png", "red"), ("2.png", "blue"), ("10.png", "green")):
        (single / name).write_bytes(png(COLORS[color]))

    epub(epubs / "葬送のフリーレン（１） - 山田鐘人 & アベツカサ.epub")
    epub(epubs / "cover-only.epub", cover=True)
    epub(epubs / "invalid-traversal.epub", bad_path=True)

    if large:
        threshold = out / "threshold"
        threshold.mkdir(exist_ok=True)
        make_exact_size_cbz(threshold / "Threshold v01.cbz", 60 * MIB)
        make_exact_size_cbz(threshold / "Threshold v02.cbz", 60 * MIB + 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path(__file__).parent / "_generated")
    parser.add_argument("--large", action="store_true", help="add ~120MiB of exact-size CBZ inputs")
    args = parser.parse_args()
    generate(args.out, large=args.large)
    print(f"Synthetic fixtures ready: {args.out.resolve()}")


if __name__ == "__main__":
    main()

"""Validate generated Phase 0 fixtures, not the Windows converter itself."""
from __future__ import annotations

import hashlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from generate_fixtures import COLORS, MIB, generate, make_exact_size_cbz, png


class BaselineFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.temp.name) / "generated"
        generate(cls.out)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def test_small_cbz_contains_single_valid_page(self) -> None:
        names = ("ONE PIECE v100.cbz", "ONE PIECE v100b.cbz",
                 "ONE PIECE v03a.cbz", "ONE PIECE（１５）.cbz")
        for name in names:
            file = self.out / "manga" / name
            self.assertTrue(file.is_file())
            self.assertLess(file.stat().st_size, 60 * MIB)
            with zipfile.ZipFile(file) as archive:
                self.assertEqual(archive.namelist(), ["001.png"])
                self.assertEqual(archive.read("001.png"), png(COLORS["red"]))

    def test_magazine_and_natural_order_folder(self) -> None:
        magazine = self.out / "magazines" / "Weekly_Ascii_2026-10-20.cbz"
        with zipfile.ZipFile(magazine) as archive:
            self.assertEqual(archive.namelist(), ["001.png"])
        folder = self.out / "single" / "単巻テスト"
        self.assertEqual({p.name for p in folder.iterdir()}, {"1.png", "2.png", "10.png"})
        self.assertEqual((folder / "2.png").read_bytes(), png(COLORS["blue"]))

    def test_epub_spine_order_is_opposite_file_order(self) -> None:
        file = self.out / "epubs" / "葬送のフリーレン（１） - 山田鐘人 & アベツカサ.epub"
        with zipfile.ZipFile(file) as archive:
            names = archive.namelist()
            self.assertEqual(names[0], "mimetype")
            self.assertEqual(archive.read("mimetype"), b"application/epub+zip")
            self.assertLess(names.index("OEBPS/page1.xhtml"), names.index("OEBPS/page2.xhtml"))
            namespace = {"opf": "http://www.idpf.org/2007/opf"}
            root = ET.fromstring(archive.read("OEBPS/content.opf"))
            refs = [n.attrib["idref"] for n in root.findall("opf:spine/opf:itemref", namespace)]
            self.assertEqual(refs, ["p2", "p1"])
            self.assertIn(b"images/blue.png", archive.read("OEBPS/page2.xhtml"))
            self.assertIn(b"images/red.png", archive.read("OEBPS/page1.xhtml"))

    def test_cover_exists_only_in_metadata(self) -> None:
        file = self.out / "epubs" / "cover-only.epub"
        with zipfile.ZipFile(file) as archive:
            self.assertIn(b'properties="cover-image"', archive.read("OEBPS/content.opf"))
            self.assertEqual(archive.read("OEBPS/images/cover.png"), png(COLORS["cover"]))
            self.assertNotIn(b"cover.png", archive.read("OEBPS/page.xhtml"))

    def test_invalid_path_is_outside_epub_root(self) -> None:
        file = self.out / "epubs" / "invalid-traversal.epub"
        with zipfile.ZipFile(file) as archive:
            self.assertIn(b"../../outside.png", archive.read("OEBPS/page.xhtml"))
            self.assertNotIn("outside.png", archive.namelist())

    def test_reproducible_and_refuses_unmarked_directory(self) -> None:
        file = self.out / "manga" / "ONE PIECE v100.cbz"
        digest = hashlib.sha256(file.read_bytes()).hexdigest()
        generate(self.out)
        self.assertEqual(hashlib.sha256(file.read_bytes()).hexdigest(), digest)
        unmarked = Path(self.temp.name) / "unmarked"
        unmarked.mkdir()
        with self.assertRaisesRegex(ValueError, "Refusing to write"):
            generate(unmarked)

    def test_exact_size_zip_generator_with_small_trial(self) -> None:
        target = Path(self.temp.name) / "small-test.cbz"
        make_exact_size_cbz(target, 4096)
        self.assertEqual(target.stat().st_size, 4096)
        with zipfile.ZipFile(target) as archive:
            self.assertEqual(archive.namelist(), ["001.png", "padding.dat"])
            self.assertEqual(archive.read("001.png"), png(COLORS["green"]))
            self.assertEqual(archive.getinfo("padding.dat").compress_type, zipfile.ZIP_STORED)


if __name__ == "__main__":
    unittest.main()

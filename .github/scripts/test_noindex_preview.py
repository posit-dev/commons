"""Tests for noindex-preview.py. Run: python3 test_noindex_preview.py"""

import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "noindex_preview", pathlib.Path(__file__).parent / "noindex-preview.py"
)
assert spec and spec.loader
noindex = importlib.util.module_from_spec(spec)
spec.loader.exec_module(noindex)

mark = noindex.mark
TAG = noindex.TAG


class MarkTest(unittest.TestCase):
    def test_adds_the_tag_inside_an_existing_head(self):
        out = mark("<!DOCTYPE html>\n<html><head><title>a</title></head></html>")
        assert out is not None
        self.assertIn(f"<head>{TAG}", out)

    def test_matches_head_case_insensitively_and_with_attributes(self):
        out = mark('<html><HEAD lang="en"><title>b</title></HEAD></html>')
        assert out is not None
        self.assertIn(f'<HEAD lang="en">{TAG}', out)

    def test_leaves_a_page_that_already_declares_robots(self):
        page = '<html><head><meta name="robots" content="noindex"></head></html>'
        self.assertIsNone(mark(page))

    def test_synthesizes_a_head_after_the_html_tag(self):
        out = mark('<html lang="en"><body>no head</body></html>')
        assert out is not None
        self.assertTrue(out.startswith(f'<html lang="en"><head>{TAG}</head>'))

    # The next three are the regressions this script actually shipped: a
    # doctype has to stay first, or the browser renders the preview in quirks
    # mode and it no longer resembles the page it previews.
    def test_keeps_a_doctype_first_when_there_is_no_html_tag(self):
        out = mark("<!DOCTYPE html>\n<body>x</body>")
        assert out is not None
        self.assertTrue(out.startswith("<!DOCTYPE html>"))
        self.assertIn(TAG, out)

    def test_keeps_a_lowercase_doctype_first(self):
        out = mark("<!doctype HTML>\n<body>x</body>")
        assert out is not None
        self.assertTrue(out.startswith("<!doctype HTML>"))

    def test_keeps_a_byte_order_mark_and_doctype_first(self):
        out = mark("﻿<!DOCTYPE html>\n<body>x</body>")
        assert out is not None
        self.assertTrue(out.startswith("﻿<!DOCTYPE html>"))
        self.assertIn(TAG, out)

    def test_leaves_a_fragment_alone(self):
        self.assertIsNone(mark("<div>bare fragment</div>\n"))

    def test_is_idempotent(self):
        once = mark("<html><head></head></html>")
        assert once is not None
        self.assertIsNone(mark(once))


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Tests for docs-postprocess.py. Run: python3 test_docs_postprocess.py"""

import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "docs_postprocess", pathlib.Path(__file__).parent / "docs-postprocess.py"
)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

fix = mod.fix
BASE = "https://posit-dev.github.io/commons/py/"


class StripVersionBadgeTest(unittest.TestCase):
    def test_removes_the_badge(self):
        page = '<span class="navbar-title">commons <span class="version-badge">v0.1.0.dev1</span></span>'
        out = fix(page, BASE, "./")
        assert out is not None
        self.assertNotIn("version-badge", out)
        self.assertNotIn("v0.1.0.dev1", out)
        # The space before the badge goes with it, leaving no dangling gap.
        self.assertIn(">commons</span>", out)

    def test_removes_the_badge_with_attributes(self):
        page = '<span class="version-badge" title="Released 2026-09-11">v0.1.0.dev1</span>'
        out = fix(page, BASE, "./")
        assert out is not None
        self.assertEqual(out.strip(), "")

    def test_leaves_a_longer_class_alone(self):
        # Anchored on the closing quote, so version-badge-legend is not a badge.
        page = '<span class="version-badge-legend">v1</span>'
        self.assertIsNone(fix(page, BASE, "./"))


class RelativizeIconsTest(unittest.TestCase):
    def test_rewrites_an_absolute_icon_link_at_the_root(self):
        page = f'<link rel="icon" href="{BASE}favicon.ico" sizes="48x48">'
        out = fix(page, BASE, "./")
        assert out is not None
        self.assertIn('href="./favicon.ico"', out)
        self.assertNotIn(BASE, out)

    def test_rewrites_with_a_nested_offset(self):
        page = f'<link rel="apple-touch-icon" href="{BASE}apple-touch-icon.png">'
        out = fix(page, BASE, "../")
        assert out is not None
        self.assertIn('href="../apple-touch-icon.png"', out)

    def test_rewrites_every_occurrence(self):
        page = (
            f'<link rel="icon" href="{BASE}favicon-16x16.png">'
            f'<link rel="icon" href="{BASE}favicon-32x32.png">'
        )
        out = fix(page, BASE, "../")
        assert out is not None
        self.assertEqual(out.count("../favicon-"), 2)
        self.assertNotIn(BASE, out)

    def test_tolerates_a_base_without_a_trailing_slash(self):
        page = f'<link rel="icon" href="{BASE}favicon.ico">'
        out = fix(page, BASE.rstrip("/"), "../")
        assert out is not None
        self.assertIn('href="../favicon.ico"', out)

    def test_leaves_an_unrelated_absolute_url_alone(self):
        page = '<a href="https://pypi.org/project/commons/">PyPI</a>'
        self.assertIsNone(fix(page, BASE, "../"))

    def test_leaves_a_page_needing_nothing(self):
        self.assertIsNone(fix("<html><body>plain</body></html>", BASE, "./"))

    def test_is_idempotent(self):
        page = (
            f'<link rel="icon" href="{BASE}favicon.ico">'
            '<span class="version-badge">v1</span>'
        )
        once = fix(page, BASE, "../")
        assert once is not None
        self.assertIsNone(fix(once, BASE, "../"))

    def test_does_both_jobs_in_one_pass(self):
        page = (
            f'<link rel="icon" href="{BASE}favicon.ico">'
            '<span class="version-badge">v0.1.0.dev1</span>'
        )
        out = fix(page, BASE, "../")
        assert out is not None
        self.assertIn('href="../favicon.ico"', out)
        self.assertNotIn("version-badge", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)

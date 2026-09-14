"""Tests for docs-version-badge.py. Run: python3 test_docs_version_badge.py"""

import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "docs_version_badge", pathlib.Path(__file__).parent / "docs-version-badge.py"
)
assert spec and spec.loader
badge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(badge)

retag = badge.retag


class RetagTest(unittest.TestCase):
    def test_replaces_the_badge_text(self):
        page = (
            '<span class="navbar-title">commons '
            '<span class="version-badge">vr-v0.1.0</span></span>'
        )
        out = retag(page, "0.1.0b1")
        assert out is not None
        self.assertIn(">v0.1.0b1<", out)
        self.assertNotIn("vr-v0.1.0", out)

    def test_keeps_the_surrounding_attributes(self):
        # The badge carries a release-date title attribute. Replacing the
        # whole tag would drop it; only the text node should change.
        page = '<span class="version-badge" title="Released 2026-09-11">vr-v0.1.0</span>'
        out = retag(page, "0.1.0b1")
        assert out is not None
        self.assertIn('title="Released 2026-09-11"', out)
        self.assertIn(">v0.1.0b1<", out)

    def test_replaces_every_occurrence(self):
        # The badge is injected into the navbar of every page, and the logo
        # tooltip carries the version too.
        page = (
            '<span class="version-badge">vr-v0.1.0</span>x'
            '<span class="version-badge">vr-v0.1.0</span>'
        )
        out = retag(page, "0.1.0b1")
        assert out is not None
        self.assertEqual(out.count(">v0.1.0b1<"), 2)

    def test_returns_none_when_there_is_no_badge(self):
        self.assertIsNone(retag("<html><body>no badge</body></html>", "0.1.0b1"))

    def test_returns_none_when_the_badge_is_already_correct(self):
        page = '<span class="version-badge">v0.1.0b1</span>'
        self.assertIsNone(retag(page, "0.1.0b1"))

    def test_is_idempotent(self):
        once = retag('<span class="version-badge">vr-v0.1.0</span>', "0.1.0b1")
        assert once is not None
        self.assertIsNone(retag(once, "0.1.0b1"))

    def test_leaves_an_unrelated_span_alone(self):
        # Anchored on the closing quote of the class attribute, so a longer
        # class name that merely starts with the same text is not a badge.
        page = '<span class="version-badge-legend">vr-v0.1.0</span>'
        self.assertIsNone(retag(page, "0.1.0b1"))


if __name__ == "__main__":
    unittest.main(verbosity=2)

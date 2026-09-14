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
ROOT = "pkg-py"
REPO = "https://github.com/posit-dev/commons"
BLOB = REPO + "/blob"


class StripVersionBadgeTest(unittest.TestCase):
    def test_removes_the_badge(self):
        page = '<span class="navbar-title">commons <span class="version-badge">v0.1.0.dev1</span></span>'
        out = fix(page, BASE, REPO, ROOT, "./")
        assert out is not None
        self.assertNotIn("version-badge", out)
        self.assertNotIn("v0.1.0.dev1", out)
        # The space before the badge goes with it, leaving no dangling gap.
        self.assertIn(">commons</span>", out)

    def test_removes_the_badge_with_attributes(self):
        page = '<span class="version-badge" title="Released 2026-09-11">v0.1.0.dev1</span>'
        out = fix(page, BASE, REPO, ROOT, "./")
        assert out is not None
        self.assertEqual(out.strip(), "")

    def test_leaves_a_longer_class_alone(self):
        # Anchored on the closing quote, so version-badge-legend is not a badge.
        page = '<span class="version-badge-legend">v1</span>'
        self.assertIsNone(fix(page, BASE, REPO, ROOT, "./"))


class RelativizeIconsTest(unittest.TestCase):
    def test_rewrites_an_absolute_icon_link_at_the_root(self):
        page = f'<link rel="icon" href="{BASE}favicon.ico" sizes="48x48">'
        out = fix(page, BASE, REPO, ROOT, "./")
        assert out is not None
        self.assertIn('href="./favicon.ico"', out)
        self.assertNotIn(BASE, out)

    def test_rewrites_with_a_nested_offset(self):
        page = f'<link rel="apple-touch-icon" href="{BASE}apple-touch-icon.png">'
        out = fix(page, BASE, REPO, ROOT, "../")
        assert out is not None
        self.assertIn('href="../apple-touch-icon.png"', out)

    def test_rewrites_every_occurrence(self):
        page = (
            f'<link rel="icon" href="{BASE}favicon-16x16.png">'
            f'<link rel="icon" href="{BASE}favicon-32x32.png">'
        )
        out = fix(page, BASE, REPO, ROOT, "../")
        assert out is not None
        self.assertEqual(out.count("../favicon-"), 2)
        self.assertNotIn(BASE, out)

    def test_tolerates_a_base_without_a_trailing_slash(self):
        page = f'<link rel="icon" href="{BASE}favicon.ico">'
        out = fix(page, BASE.rstrip("/"), REPO, ROOT, "../")
        assert out is not None
        self.assertIn('href="../favicon.ico"', out)

    def test_leaves_the_versioned_canonical_script_alone(self):
        # great-docs injects a canonical-URL script whose base is the site URL
        # without a trailing slash, and builds a path onto it at runtime.
        # Rewriting it to a page-relative prefix would produce a bogus
        # canonical URL on every non-latest version.
        page = '<script>var base="https://posit-dev.github.io/commons/py";</script>'
        self.assertIsNone(fix(page, BASE, REPO, ROOT, "../"))

    def test_leaves_a_script_using_the_trailing_slash_form_alone(self):
        # Same risk, one character different: only <link> hrefs are rewritten.
        page = f'<script>var base="{BASE}";</script>'
        self.assertIsNone(fix(page, BASE, REPO, ROOT, "../"))

    def test_rewrites_the_link_but_not_a_neighbouring_script(self):
        page = (
            f'<link rel="icon" href="{BASE}favicon.ico">'
            f'<script>var base="{BASE}";</script>'
        )
        out = fix(page, BASE, REPO, ROOT, "../")
        assert out is not None
        self.assertIn('href="../favicon.ico"', out)
        self.assertIn(f'var base="{BASE}";', out)

    def test_leaves_an_unrelated_absolute_url_alone(self):
        page = '<a href="https://pypi.org/project/commons/">PyPI</a>'
        self.assertIsNone(fix(page, BASE, REPO, ROOT, "../"))

    def test_leaves_a_page_needing_nothing(self):
        self.assertIsNone(fix("<html><body>plain</body></html>", BASE, REPO, ROOT, "./"))

    def test_is_idempotent(self):
        page = (
            f'<link rel="icon" href="{BASE}favicon.ico">'
            '<span class="version-badge">v1</span>'
        )
        once = fix(page, BASE, REPO, ROOT, "../")
        assert once is not None
        self.assertIsNone(fix(once, BASE, REPO, ROOT, "../"))

    def test_does_both_jobs_in_one_pass(self):
        page = (
            f'<link rel="icon" href="{BASE}favicon.ico">'
            '<span class="version-badge">v0.1.0.dev1</span>'
        )
        out = fix(page, BASE, REPO, ROOT, "../")
        assert out is not None
        self.assertIn('href="../favicon.ico"', out)
        self.assertNotIn("version-badge", out)


class SourceLinkTest(unittest.TestCase):
    def test_inserts_the_package_root(self):
        page = f'<a href="{BLOB}/main/src/commons/_agent.py#L58-L368">source</a>'
        out = fix(page, BASE, REPO, ROOT, "./")
        assert out is not None
        self.assertIn(f"{BLOB}/main/pkg-py/src/commons/_agent.py#L58-L368", out)

    def test_keeps_a_nested_module_path(self):
        # source.path would have flattened this to the basename, which is why
        # the prefix is inserted here instead of configured there.
        page = f'<a href="{BLOB}/main/src/commons/_ui/_server.py#L1-L2">source</a>'
        out = fix(page, BASE, REPO, ROOT, "./")
        assert out is not None
        self.assertIn(f"{BLOB}/main/pkg-py/src/commons/_ui/_server.py", out)

    def test_handles_a_ref_containing_slashes(self):
        page = f'<a href="{BLOB}/jat255/some-branch/src/commons/_agent.py">source</a>'
        out = fix(page, BASE, REPO, ROOT, "./")
        assert out is not None
        self.assertIn(f"{BLOB}/jat255/some-branch/pkg-py/src/commons/_agent.py", out)

    def test_is_idempotent_on_source_links(self):
        page = f'<a href="{BLOB}/jat255/some-branch/pkg-py/src/commons/_agent.py">source</a>'
        self.assertIsNone(fix(page, BASE, REPO, ROOT, "./"))

    def test_leaves_another_repository_alone(self):
        # Only this repository's generated links need the package directory;
        # a link into someone else's src/ tree must be untouched.
        page = '<a href="https://github.com/tidyverse/dplyr/blob/main/src/init.c">x</a>'
        self.assertIsNone(fix(page, BASE, REPO, ROOT, "./"))

    def test_tolerates_a_repo_url_with_a_trailing_slash(self):
        page = f'<a href="{BLOB}/main/src/commons/_agent.py">source</a>'
        out = fix(page, BASE, REPO + "/", ROOT, "./")
        assert out is not None
        self.assertIn("/main/pkg-py/src/commons/_agent.py", out)

    def test_leaves_a_non_source_repo_link_alone(self):
        page = f'<a href="https://github.com/posit-dev/commons/issues/12">issue</a>'
        self.assertIsNone(fix(page, BASE, REPO, ROOT, "./"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
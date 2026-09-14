"""Correct two things great-docs bakes into the built Python docs site.

**Absolute icon links.** great-docs writes the favicon `<link>` hrefs against
`site_url`, so every page points at the published site. They resolve to the
wrong place, or to nothing, when the same build is served from anywhere else:
a pull request preview under `pr-<n>/py/`, a local preview, or a versioned copy
under `v/<tag>/`. The generated icons sit at the root of each copy, so Quarto's
own per-page offset is the right prefix.

**The navbar version badge.** great-docs derives it from the newest GitHub
Release for the whole repository and cannot filter by tag prefix, so in this
monorepo it shows whichever of the two release series published last. The
version selector already names the version, from the list in great-docs.yml,
so the badge is removed rather than corrected.

Remove the corresponding half of this script if great-docs gains relative icon
links, or a way to suppress the badge.

Usage: docs-postprocess.py <site-directory> <site-url>
"""

from __future__ import annotations

import pathlib
import re
import sys

# The closing quote after the class name is what stops a longer class that
# merely starts the same way, such as version-badge-legend, from matching.
BADGE = re.compile(r'\s*<span class="version-badge"[^>]*>[^<]*</span>')

OFFSET = re.compile(r'<meta name="quarto:offset" content="([^"]*)"')

# Only <link> tags are rewritten. great-docs also injects a canonical-URL
# script whose base is the site URL, which it concatenates with a path at
# runtime; turning that into a page-relative prefix would yield a bogus
# canonical URL on every non-latest version.
LINK = re.compile(r"<link\b[^>]*>")


def fix(text: str, site_url: str, offset: str) -> str | None:
    """Return `text` with icon links made relative and the badge removed.

    Returns None when the page needs neither, which keeps the caller from
    rewriting a file it does not have to touch and makes this idempotent.
    """
    base = site_url if site_url.endswith("/") else site_url + "/"
    prefix = offset if offset.endswith("/") else offset + "/"

    icons = 0

    def relativize(match: re.Match[str]) -> str:
        nonlocal icons
        tag, n = re.subn(
            r'(?<=href=")' + re.escape(base), prefix, match.group(0)
        )
        icons += n
        return tag

    patched = LINK.sub(relativize, text)
    patched, badges = BADGE.subn("", patched)

    if not (icons or badges) or patched == text:
        return None
    return patched


def main(root: str, site_url: str) -> int:
    directory = pathlib.Path(root)
    if not directory.is_dir():
        print(f"{root} is not a directory", file=sys.stderr)
        return 1

    changed = skipped = 0
    for path in sorted(directory.rglob("*.html")):
        text = path.read_text(encoding="utf-8", errors="surrogateescape")
        # Each page carries the offset to its own copy's root, which is what
        # makes this correct inside a versioned copy as well as at the top.
        found = OFFSET.search(text)
        offset = found.group(1) if found else "./"
        patched = fix(text, site_url, offset)
        if patched is None:
            skipped += 1
            continue
        path.write_text(patched, encoding="utf-8", errors="surrogateescape")
        changed += 1

    print(f"Post-processed {changed} page(s), skipped {skipped}.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2]))

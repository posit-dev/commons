"""Correct the navbar version badge on a built Python docs site, in place.

great-docs writes the badge from the newest GitHub Release for the whole
repository, with no way to filter by tag prefix. This is a monorepo with two
release series, `r-v*` and `py-v*`, so the badge shows whichever package
released most recently and is wrong roughly half the time. The version in
pkg-py/pyproject.toml is the only authority for what the Python site
documents, so the badge is rewritten from it after the site is built.

The badge is injected by great-docs' own post-render step, which runs inside
`great-docs build`, so there is no point at which the metadata it reads could
be corrected instead.

Remove this script if great-docs gains a version override or a tag-prefix
filter.

Usage: docs-version-badge.py <site-directory> <version>
"""

from __future__ import annotations

import pathlib
import re
import sys

# The closing quote after the class name is what stops a longer class that
# merely starts the same way, such as version-badge-legend, from matching. The
# release-date title attribute is dropped rather than captured: see below.
BADGE = re.compile(r'<span class="version-badge"[^>]*>[^<]*</span>')

# When the navbar carries a logo rather than a text title, great-docs puts the
# version in a Tippy tooltip on the brand link instead of a badge span, so the
# same wrong version arrives by a second route. Anchoring on the opening
# `<code>v` is what distinguishes it from every other tooltip on the page. The
# optional trailing clause is the release date, dropped with it.
TOOLTIP = re.compile(r'(data-tippy-content=")<code>v[^<]*</code>(?:<br>[^"]*)?(")')


def retag(text: str, version: str) -> str | None:
    """Return `text` with every version reading `v<version>`, or None if unchanged.

    Returning None for "nothing to do" keeps the caller from rewriting a file
    it does not need to touch, and makes the function idempotent.
    """
    wanted = f"v{version}"

    def replace_tooltip(match: re.Match[str]) -> str:
        return f"{match.group(1)}<code>{wanted}</code>{match.group(2)}"

    # Both forms are rebuilt rather than edited in place, because the release
    # date great-docs pairs with the version comes from the same wrong GitHub
    # Release and pyproject.toml has no date to replace it with. Asserting the
    # R package's release date next to the Python version would be a second
    # wrong claim, so it is removed.
    patched, badges = BADGE.subn(f'<span class="version-badge">{wanted}</span>', text)
    patched, tooltips = TOOLTIP.subn(replace_tooltip, patched)
    if not (badges or tooltips) or patched == text:
        return None
    return patched


def main(root: str, version: str) -> int:
    directory = pathlib.Path(root)
    if not directory.is_dir():
        print(f"{root} is not a directory", file=sys.stderr)
        return 1

    changed = skipped = 0
    for path in sorted(directory.rglob("*.html")):
        text = path.read_text(encoding="utf-8", errors="surrogateescape")
        patched = retag(text, version)
        if patched is None:
            skipped += 1
            continue
        path.write_text(patched, encoding="utf-8", errors="surrogateescape")
        changed += 1

    print(f"Corrected the version badge on {changed} page(s), skipped {skipped}.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2]))

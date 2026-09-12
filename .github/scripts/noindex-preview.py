"""Mark every page of a built site as noindex, in place.

Pull request previews live under posit-dev.github.io/commons/pr-<number>/.
Crawlers read robots.txt only at the origin root, and this repository does not
own posit-dev.github.io, so a robots.txt shipped with the site is never
consulted. A meta tag travels with the page instead.

Usage: noindex-preview.py <directory>
"""

from __future__ import annotations

import pathlib
import re
import sys

TAG = '<meta name="robots" content="noindex, nofollow">'
HEAD = re.compile(r"<head[^>]*>", re.IGNORECASE)
# A byte order mark may precede the doctype, and the doctype only counts as
# one if nothing but that precedes it. Inserting above either drops the
# browser into quirks mode, so the preview would render unlike the real page.
DOCUMENT = re.compile(r"﻿?\s*<!doctype[^>]*>|<html[^>]*>", re.IGNORECASE)


def mark(text: str) -> str | None:
    """Return `text` with the tag added, or None if it needs no change.

    A file with neither a head, an html tag, nor a doctype is a fragment
    rather than a page. Nothing indexes it on its own, and giving it a head
    would only corrupt whatever embeds it.
    """
    if 'name="robots"' in text:
        return None

    patched, count = HEAD.subn(lambda m: m.group(0) + TAG, text, count=1)
    if count:
        return patched

    patched, count = DOCUMENT.subn(
        lambda m: m.group(0) + f"<head>{TAG}</head>", text, count=1
    )
    return patched if count else None


def main(root: str) -> int:
    directory = pathlib.Path(root)
    if not directory.is_dir():
        print(f"{root} is not a directory", file=sys.stderr)
        return 1

    marked = skipped = 0
    for path in sorted(directory.rglob("*.html")):
        text = path.read_text(encoding="utf-8", errors="surrogateescape")
        patched = mark(text)
        if patched is None:
            skipped += 1
            continue
        path.write_text(patched, encoding="utf-8", errors="surrogateescape")
        marked += 1

    print(f"Marked {marked} page(s) noindex, skipped {skipped}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))

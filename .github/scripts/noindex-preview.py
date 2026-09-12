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
HTML = re.compile(r"<html[^>]*>", re.IGNORECASE)
# Anchored, and tolerant of a leading byte order mark, because a doctype
# counts as one only when nothing but that precedes it. The anchor is also
# what keeps a fragment that merely quotes a doctype from passing as a
# document. Written as an escape: a literal mark here would be invisible.
DOCTYPE = re.compile("\\A\\ufeff?\\s*<!doctype[^>]*>", re.IGNORECASE)


def mark(text: str) -> str | None:
    """Return `text` with the tag added, or None if it needs no change.

    A file with no head, no html tag, and no leading doctype is a fragment
    rather than a page. Nothing indexes it on its own, and giving it a head
    would only corrupt whatever embeds it.
    """
    if 'name="robots"' in text:
        return None

    patched, count = HEAD.subn(lambda m: m.group(0) + TAG, text, count=1)
    if count:
        return patched

    # The html tag is tried before the doctype because a head belongs inside
    # html. Taking whichever appears first in the text would put the head
    # between the two on every page that has both.
    head = f"<head>{TAG}</head>"
    for pattern in (HTML, DOCTYPE):
        patched, count = pattern.subn(lambda m: m.group(0) + head, text, count=1)
        if count:
            return patched
    return None


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

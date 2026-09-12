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
DOCTYPE = re.compile(r"^\s*<!doctype[^>]*>", re.IGNORECASE)


def main(root: str) -> int:
    directory = pathlib.Path(root)
    if not directory.is_dir():
        print(f"{root} is not a directory", file=sys.stderr)
        return 1

    marked = skipped = 0
    for path in sorted(directory.rglob("*.html")):
        text = path.read_text(encoding="utf-8", errors="surrogateescape")
        if 'name="robots"' in text:
            skipped += 1
            continue
        patched, count = HEAD.subn(lambda m: m.group(0) + TAG, text, count=1)
        if not count:
            # The head start tag is optional in HTML, and neither generator
            # omits it today. Synthesize one anyway rather than deploy a page
            # that is still indexable. Failing the run instead would let one
            # stray fragment block every preview, which is the worse trade
            # for a file that is usually not a page at all.
            print(f"No <head> in {path}, inserting one", file=sys.stderr)
            head = f"<head>{TAG}</head>"
            # After <html> where there is one, otherwise after a leading
            # doctype. A doctype has to come first in the document: put the
            # head above it and the browser drops into quirks mode, which
            # would make the preview render unlike the real page.
            patched, count = HTML.subn(lambda m: m.group(0) + head, text, count=1)
            if not count:
                patched, count = DOCTYPE.subn(
                    lambda m: m.group(0) + head, text, count=1
                )
            if not count:
                patched = head + text
        path.write_text(patched, encoding="utf-8", errors="surrogateescape")
        marked += 1

    print(f"Marked {marked} page(s) noindex, skipped {skipped}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))

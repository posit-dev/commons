#!/usr/bin/env bash
# Point <docs>/r/ at the development site when that is the only site built.
#
# pkgdown's automatic development mode sends a released version's site to the
# root of its destination and a development version's to dev/ below it. Every
# build from a branch is a development version, so r/ is empty and the landing
# page's link to it lands on nothing.
#
# Moving dev/ up is the obvious fix and the wrong one: the build writes its own
# absolute address into search.json, sitemap.xml, and the pages themselves, so
# a moved tree keeps telling the browser to go to r/dev/, and site search
# breaks. A redirect leaves the build untouched.
#
# Only for local previews and pull request previews. On the published site r/
# is the released documentation, and overwriting its index with a redirect to
# the development docs would be a regression for every reader.
set -euo pipefail

docs="${1:?usage: link-r-dev.sh <docs directory>}"

if [ -f "$docs/r/index.html" ]; then
  echo "r/ already has an index, leaving it alone."
  exit 0
fi
if [ ! -f "$docs/r/dev/index.html" ]; then
  echo "Neither r/ nor r/dev/ has an index, nothing to point at." >&2
  exit 0
fi

cat > "$docs/r/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="robots" content="noindex, nofollow">
<meta http-equiv="refresh" content="0; url=dev/">
<title>Redirecting to the development documentation</title>
</head>
<body>
<p>This preview contains the development documentation. Redirecting to <a href="dev/">dev/</a>.</p>
</body>
</html>
HTML

echo "Wrote $docs/r/index.html, redirecting to dev/."

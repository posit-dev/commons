#!/usr/bin/env bash
# Build the documentation sites and serve them the way they are deployed.
#
# The sites are published as one tree: the landing page at the root, the R
# site under r/, and the Python site under py/. Their links to each other are
# relative, so opening a built file directly resolves none of them. This
# script assembles that same tree in docs/ and serves it, which is also the
# layout a pull request preview publishes, so what you see here is what a
# reviewer sees there.
#
# Usage:
#   scripts/preview-docs.sh            build both sites and serve
#   scripts/preview-docs.sh r          build only the R site and serve
#   scripts/preview-docs.sh py         build only the Python site and serve
#   scripts/preview-docs.sh --no-serve build, then stop
#   scripts/preview-docs.sh --port 8000
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sites=""
serve=true
port=4444

while [ $# -gt 0 ]; do
  case "$1" in
    r|py) sites="$sites $1" ;;
    --no-serve) serve=false ;;
    --port) shift; port="${1:?--port needs a number}" ;;
    # Prints the header block, stopping at the first line that is not a
    # comment, so the two cannot drift apart.
    -h|--help) sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$sites" ] || sites="r py"

# Collected rather than printed as they happen, so the reason a site is
# missing is still on screen once a build has scrolled past.
skipped=()

build_r() {
  if ! command -v Rscript >/dev/null 2>&1; then
    skipped+=("r: Rscript is not on PATH")
    return
  fi
  if ! Rscript -e 'quit(status = !requireNamespace("pkgdown", quietly = TRUE))' 2>/dev/null; then
    skipped+=("r: the pkgdown package is not installed (install.packages(\"pkgdown\"))")
    return
  fi
  # pkgdown runs the examples, so it needs commons itself installed, exactly
  # as the workflow does through setup-r-dependencies. Checking here turns
  # what is otherwise a long build ending in an R stack trace into one line.
  if ! Rscript -e 'quit(status = !requireNamespace("commons", quietly = TRUE))' 2>/dev/null; then
    skipped+=("r: commons is not installed (pak::local_install_deps(\"pkg-r\"), then pak::local_install(\"pkg-r\"))")
    return
  fi
  echo "==> Building the R site into docs/r"
  # Matches .github/workflows/pkgdown.yaml. The destination comes from
  # pkg-r/_pkgdown.yml, so it lands in docs/r without being named here.
  (cd "$root/pkg-r" && Rscript -e 'pkgdown::build_site(new_process = FALSE, install = FALSE)')
}

build_py() {
  if ! command -v uv >/dev/null 2>&1; then
    skipped+=("py: uv is not on PATH (https://docs.astral.sh/uv/)")
    return
  fi
  if ! command -v quarto >/dev/null 2>&1; then
    skipped+=("py: quarto is not on PATH (https://quarto.org/docs/get-started/)")
    return
  fi
  echo "==> Building the Python site into docs/py"
  # Matches .github/workflows/quartodoc.yaml, including the copy: quarto
  # warns and refuses to clean an output directory outside its project, so
  # the site renders in place and is copied into position.
  (cd "$root/pkg-py" && uv sync --extra shiny --group docs --quiet)
  (cd "$root/pkg-py/docs" && uv run quartodoc build && uv run quarto render)
  rm -rf "$root/docs/py"
  cp -r "$root/pkg-py/docs/_site" "$root/docs/py"
}

for site in $sites; do
  "build_$site"
done

for note in "${skipped[@]+"${skipped[@]}"}"; do
  echo "Skipped $note" >&2
done

# Naming what is absent beats letting someone click a dead link and wonder
# whether they broke the build.
for site in r py; do
  [ -d "$root/docs/$site" ] || echo "Note: docs/$site is not built, so links to it will 404." >&2
done

if [ "$serve" = true ]; then
  echo "==> Serving $root/docs at http://localhost:$port/ (Ctrl-C to stop)"
  cd "$root/docs" && python3 -m http.server "$port"
fi

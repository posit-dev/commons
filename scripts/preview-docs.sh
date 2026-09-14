#!/usr/bin/env bash
# Build the documentation sites and serve them the way they are deployed.
#
# The sites are published as one tree: the landing page at the root, the R
# site under r/, and the Python site under py/. This script assembles that
# tree in docs/ and serves it, so both sites can be read together the way a
# reader meets them. Only the Python site gets a pull request preview, so for
# the R site this is the only rendered view before it is deployed.
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
# missing is still on screen once a build has scrolled past. Each entry is a
# reason followed by a command to paste: naming a package leaves the reader to
# work out where to type it, and the answer differs between the shell and the
# R console.
skipped=()

# skip <what> <reason> [command...]
#
# Commands are printed one per line, indented and with nothing in front of
# them, so a block can be selected and pasted as-is. No box drawing, because
# the border characters come along with the copy.
skip() {
  local what="$1" reason="$2"
  shift 2
  local block="Skipped $what: $reason"
  if [ $# -gt 0 ]; then
    block="$block

  To fix it, run:
"
    local command
    for command in "$@"; do
      block="$block
    $command"
    done
  fi
  skipped+=("$block")
}

build_r() {
  if ! command -v Rscript >/dev/null 2>&1; then
    skip "the R site" "Rscript is not on PATH. Install R from https://cloud.r-project.org/."
    return
  fi
  if ! Rscript -e 'quit(status = !requireNamespace("pkgdown", quietly = TRUE))' 2>/dev/null; then
    skip "the R site" "pkgdown is not installed." \
      "Rscript -e 'install.packages(\"pkgdown\", repos = \"https://cloud.r-project.org\")'"
    return
  fi
  # pkgdown runs the examples, so it needs commons itself installed, exactly
  # as the workflow does through setup-r-dependencies. Checking here turns
  # what is otherwise a long build ending in an R stack trace into one line.
  #
  # The snippet installs pak first if it has to, and runs from $root, so it
  # works whatever directory the reader pasted it into.
  if ! Rscript -e 'quit(status = !requireNamespace("commons", quietly = TRUE))' 2>/dev/null; then
    # Absolute paths, so no cd is needed and pasting these does not move the
    # reader's shell. The pak line appears only when pak is actually absent,
    # rather than as a conditional the reader has to evaluate.
    local install=()
    if ! Rscript -e 'quit(status = !requireNamespace("pak", quietly = TRUE))' 2>/dev/null; then
      install+=("Rscript -e 'install.packages(\"pak\", repos = \"https://cloud.r-project.org\")'")
    fi
    install+=("Rscript -e 'pak::local_install_deps(\"$root/pkg-r\")'")
    install+=("Rscript -e 'pak::local_install(\"$root/pkg-r\")'")
    skip "the R site" "commons is not installed, and pkgdown runs its examples." \
      "${install[@]}"
    return
  fi
  echo "==> Building the R site into docs/r"
  # Matches .github/workflows/pkgdown.yaml. The destination comes from
  # pkg-r/_pkgdown.yml, so it lands in docs/r without being named here.
  #
  # pkgdown and rmarkdown ask pandoc for math with the --mathml and --mathjax
  # spellings pandoc 3.11 deprecated, once per topic and per vignette, and
  # neither flag is ours to set. Drop those lines from stderr and leave
  # everything else, including the exit status, alone.
  {
    (cd "$root/pkg-r" && Rscript -e 'pkgdown::build_site(new_process = FALSE, install = FALSE)') \
      2>&1 1>&3 | sed '/^\[WARNING\] Deprecated: --math/d' >&2
  } 3>&1
}

build_py() {
  if ! command -v uv >/dev/null 2>&1; then
    skip "the Python site" "uv is not on PATH." \
      "curl -LsSf https://astral.sh/uv/install.sh | sh"
    return
  fi
  if ! command -v quarto >/dev/null 2>&1; then
    skip "the Python site" "quarto is not on PATH. Install it from https://quarto.org/docs/get-started/."
    return
  fi
  echo "==> Building the Python site into docs/py"
  # Matches .github/workflows/quartodoc.yaml, including the copy and the
  # version correction: great-docs renders in place, because quarto warns and
  # refuses to clean an output directory outside its project.
  (cd "$root/pkg-py" && uv sync --extra shiny --group docs --quiet)
  (cd "$root/pkg-py" && uv run great-docs build)
  version="$(cd "$root/pkg-py" && uv run python -c 'import tomllib; print(tomllib.load(open("pyproject.toml","rb"))["project"]["version"])')"
  (cd "$root/pkg-py" && uv run python "$root/.github/scripts/docs-version-badge.py" great-docs/_site "$version")
  rm -rf "$root/docs/py"
  cp -r "$root/pkg-py/great-docs/_site" "$root/docs/py"
}

for site in $sites; do
  "build_$site"
done

for note in "${skipped[@]+"${skipped[@]}"}"; do
  printf '\n%s\n' "$note" >&2
done
[ ${#skipped[@]} -eq 0 ] || echo >&2

# pkgdown's automatic development mode decides where a site lands from the
# version in DESCRIPTION: a released version goes to the root of destination,
# a development version to dev/ below it. So the R entry point moves between
# builds, and the addresses below are worth reading rather than guessing.
entry_point() {
  if [ -f "$root/docs/$1/index.html" ]; then
    echo "$1/"
  elif [ -f "$root/docs/$1/dev/index.html" ]; then
    echo "$1/dev/"
  fi
}

echo
echo "Pages:"
printf '  %-14s http://localhost:%s/ \n' "landing page" "$port"
for site in r py; do
  case "$site" in
    r) label="R site" ;;
    py) label="Python site" ;;
  esac
  path="$(entry_point "$site")"
  if [ -n "$path" ]; then
    printf '  %-14s http://localhost:%s/%s \n' "$label" "$port" "$path"
  else
    # Named rather than omitted: a missing row reads as a broken build.
    printf '  %-14s not built, so links to it will 404\n' "$label"
  fi
done
echo

if [ "$serve" = true ]; then
  echo "==> Serving $root/docs (Ctrl-C to stop)"
  cd "$root/docs" && python3 -m http.server "$port"
fi

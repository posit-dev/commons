# Migrating to the monorepo

The R package moved from the repository root into `pkg-r/`, to make room for a Python implementation in `pkg-py/` and shared cross-language fixtures in `tests/shared/`. The package itself is unchanged: no code, no exports, no tests were edited in the move. What changes is where you stand when you run things.

You do not need to re-clone. `git pull` is enough.

## The one thing to internalize

**R tooling now runs from `pkg-r/`, not the repository root.** Almost everything below follows from that.

```r
setwd("pkg-r")   # or open pkg-r/commons.Rproj
devtools::load_all()
```

| Before | After |
|---|---|
| open `commons.Rproj` | open `pkg-r/commons.Rproj` |
| `devtools::load_all()` at root | same, from `pkg-r/` |
| `devtools::test()`, `document()`, `check()` at root | same, from `pkg-r/` |
| `R CMD check .` at root | `R CMD check .` from `pkg-r/` |
| `pak::pak("posit-dev/commons")` | `pak::pak("posit-dev/commons/pkg-r")` |

If you run R from the root by habit, the failure is loud and immediate (`DESCRIPTION` not found), not subtle.

## What moved and what did not

Moved into `pkg-r/`: `R/ man/ tests/ src/ inst/ vignettes/ DESCRIPTION NAMESPACE _pkgdown.yml .Rbuildignore commons.Rproj cran-comments.md README.md README.Rmd LICENSE LICENSE.md`.

Stayed at the root: `.github/`, `AGENTS.md` and its `CLAUDE.md` symlink, and a repository-level `README.md`. `LICENSE` and `LICENSE.md` now exist in both places — `R CMD check` needs them inside the package, GitHub needs them at the root.

## In-flight branches

Rebase onto the restructure rather than merging. Git's rename detection maps your edits onto the new paths, so a branch that touches `R/citations.R` lands on `pkg-r/R/citations.R` without manual intervention:

```sh
git rebase main
```

Rename detection is per-file and works on content similarity, so it can miss if a branch also rewrites the file heavily. If a conflict shows your change against a deleted path, the file is not gone — resolve it at the `pkg-r/` path.

## `.gitignore` split in two

Package-relative patterns now live in `pkg-r/.gitignore`; the root keeps only patterns without an internal separator, which match at any depth and so cover both packages.

This was not cosmetic. A gitignore pattern containing a separator is anchored to the directory of the file that declares it, so `inst/resources/`, `inst/tiles/`, `inst/pkgs`, `inst/hex/output`, and `src/*.{o,so,dll}` all silently stopped matching the moment the package moved — compiled objects and generated asset directories would have quietly become committable. Nothing for you to do; this is just why the file looks different.

## CI

Each workflow now has a `paths:` filter and runs with `working-directory: pkg-r`. The R workflows trigger on `pkg-r/**` and `tests/shared/**`; the new `py-check` triggers on `pkg-py/**` and `tests/shared/**`.

Two consequences worth knowing:

- A PR touching only `pkg-py/` will not run the R checks at all. That is intended.
- **If any R check is a required status check in branch protection, that needs adjusting.** GitHub leaves a required check that never runs in a pending state forever, which blocks the merge. This is the one piece of the restructure that needs repository-admin attention rather than a code change.

`deploy.yml` now deploys `pkg-r/inst` to Connect. Left unchanged it would have kept "succeeding" against a path that no longer exists.

## Two new conventions

**Release tags are prefixed per package:** `r-v*` for R, `py-v*` for Python. Nothing enforces this yet — there is no release workflow in the repository — so for now it is a convention to follow by hand.

**Shared behavior belongs in `tests/shared/`.** Anything both implementations must agree on — the system prompt, the citation dialect and its guards, the provenance truth table and display copy, the tracing span contract — goes there as an executable fixture that both suites read, rather than as prose or as a per-language copy. This is the reason the two packages share a repository at all: prompt drift fails invisibly, so a per-language copy of a shared expectation counts as a review defect. See [`tests/shared/README.md`](tests/shared/README.md).

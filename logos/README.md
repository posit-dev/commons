# Site logos

The language marks the documentation site navbars show: `python-logo.svg`
beside the Python site's title, and `r-logo.svg` both beside the R site's
title and as the Python site's link to the R site. The Python mark is the
PSF's (via Wikimedia); the R mark is from r-project.org (CC BY-SA 4.0).

`scripts/sync-shared.sh` copies this directory into `pkg-py/docs/assets/logos/`
and `pkg-r/pkgdown/assets/logos/`, and CI fails when a copy is stale. Edit the
files here, never a copy.

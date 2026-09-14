# Site icons

The icons every page of the documentation tree serves: the landing page, the R
site, and the Python site. Generated from `pkg-r/man/figures/logo.png` by
`pkgdown::build_favicons()`, whose file names the R site expects, so keep them
as they are.

`scripts/sync-shared.sh` copies this directory into `pkg-r/pkgdown/favicon/`,
`pkg-py/docs/favicon/`, and `docs/favicon/`, and CI fails when a copy is stale.
Edit the files here, never a copy.

The icon paths in `site.webmanifest` are relative, because each site serves its
own copy from a different prefix. The `<link>` tags live with each site: the
pkgdown template writes them for the R site, `include_in_header` in
`pkg-py/great-docs.yml` for the Python site, and `docs/index.html` for the
landing page.

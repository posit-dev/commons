# Hex sticker

`commons-hex.png` is the package's hex sticker, shown on the landing page and at the top of the Python site's home page. It is a web-sized reduction of `pkg-r/inst/hex/commons.png`, which `pkg-r/inst/hex/make_hex.py` generates from the source artwork.

`scripts/sync-shared.sh` copies this directory into `docs/assets/hex/` and `pkg-py/docs/assets/hex/`, and CI fails when a copy is stale. Edit the file here, never a copy.

The R site does not get a copy: pkgdown picks the sticker up from `pkg-r/man/figures/logo.png` by convention, which is also what the R README embeds.

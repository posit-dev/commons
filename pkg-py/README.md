# posit-commons

The Python port of [commons](../pkg-r): a constructor for trustworthy data agents with the same three layers (data, semantic, context), the same seven tools, and the same A/B/C provenance semantics as the R package.

Distribution name `posit-commons`, import name `commons`. The distribution name is a placeholder: `commons`, `pycommons`, and `py-commons` are all taken on PyPI.

**Status: scaffolding.** This directory currently holds only enough to keep CI honest. The package itself does not exist yet.

Cross-language behavior is pinned by fixtures in [`tests/shared/`](../tests/shared), which this suite reads directly rather than restating.

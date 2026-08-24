# posit-commons

`commons` is a constructor for trustworthy data agents. Once implemented, this package will give an LLM data, semantic, and context layers to work with, tools for querying them, and A/B/C provenance semantics so every answer carries a classification as to its trustworthiness.

The distribution name on PyPI is `posit-commons`, but the package is imported as `commons`.

**Status: pre-alpha.** The package installs, imports, lints, type-checks, and tests, but exports nothing yet: `commons.__all__` is empty and there is no public API. Python 3.11 or later is required.

Behavior shared across implementations is pinned by fixtures in [`tests/shared/`](../tests/shared), which this suite reads directly rather than restating.

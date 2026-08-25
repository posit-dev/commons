# posit-commons

`commons` is a constructor for trustworthy data agents. Once implemented, this package will give an LLM data, semantic, and context layers to work with, tools for querying them, and A/B/C provenance tags used to derive provenance outcomes for answers.

The distribution name on PyPI is `posit-commons`, but the package is imported as `commons`.

**Status: pre-alpha.** The package installs, imports, lints, type-checks, and tests, but exports nothing yet: `commons.__all__` is empty and there is no public API. Python 3.11 or later is required.

Behavior that both implementations must agree on belongs in [`tests/shared/`](https://github.com/posit-dev/commons/tree/main/tests/shared) at the repository root, which that directory's README defines as the authority. The provenance tag rules and display copy are the first behavior governed that way; both suites run those cases.

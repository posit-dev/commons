# commons

`commons` is a constructor for trustworthy data agents. Once implemented, this package will give an LLM data, semantic, and context layers to work with, tools for querying them, and A/B/C provenance tags so every answer carries a classification as to its trustworthiness.

**Status: pre-alpha.** The package exports the data and semantic layers (`data_source`, `measure`, `semantic_layer`, and their types); the agent constructor that ties them together is not implemented yet. Python 3.11 or later is required.

Behavior that both implementations must agree on belongs in [`tests/shared/`](https://github.com/posit-dev/commons/tree/main/tests/shared) at the repository root, which that directory's README defines as the authority. The provenance tag rules and display copy are the first behavior governed that way; both suites run those cases.

# commons

Build correct and easy-to-use self-service data science tools. commons assembles a data agent from three layers — data, semantic, and context — and holds it to A/B/C provenance semantics, so every answer it gives can be traced back to what produced it.

This repository holds two implementations of the same design:

| Directory | Package | Language |
|---|---|---|
| [`pkg-r/`](pkg-r) | `commons` | R |
| [`pkg-py/`](pkg-py) | `posit-commons` (imports as `commons`) | Python |
| [`tests/shared/`](tests/shared) | cross-language spec fixtures | — |

The R package is released and in use; the Python package is early scaffolding.

## Installing

```r
# install.packages("pak")
pak::pak("posit-dev/commons/pkg-r")
```

The `/pkg-r` suffix is required — the package no longer lives at the repository root.

## Why one repository

commons' behavior lives substantially in artifacts that have to agree across both languages: the system prompt, the citation dialect and its guards, the provenance truth table and its display copy, and the tracing span contract. Kept in separate repositories, each of those is a copy that drifts silently, and prompt drift fails invisibly — nothing errors, the agent just behaves differently in one language.

`tests/shared/` exists so those contracts are executable fixtures that CI enforces, read by both test suites, rather than prose that rots. See [`tests/shared/README.md`](tests/shared/README.md).

## Working in this repository

Each package builds and tests from its own directory, and CI is scoped to match: the R workflows run on `pkg-r/**`, py-check runs on `pkg-py/**`, and both run on `tests/shared/**`.

If you worked in this repository before the split, [`MIGRATING.md`](MIGRATING.md) covers what moved and what to change in your setup.

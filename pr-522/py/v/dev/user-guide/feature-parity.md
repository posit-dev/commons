# Feature parity with the R package

While both Python and R packages are first-class implementations of `commons`, the R implementation was developed first, and the Python package does not yet implement everything the R package does. This page lists the gaps that remain as of the current version and what a Python agent does instead.

| R-only feature | What a Python agent does instead |
|----|----|
| `trajectory_read()`, for reading logged conversations | No equivalent yet |
| The commons agent skill for coding agents | Ships with the R package only |
| Reports written as Quarto documents, shown in the chat's drawer and revised with `edit_artifact` | Answers in the chat only |
| Sharing a conversation, document, plot, or table to Posit Connect | No equivalent yet ([\#517](https://github.com/posit-dev/commons/issues/517)) |

This page will shrink (and eventually disappear) as the Python package matures.

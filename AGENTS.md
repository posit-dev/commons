This repository is a monorepo holding two implementations of commons: the R package in `pkg-r/`, the Python package in `pkg-py/`, and cross-language spec fixtures in `tests/shared/`. Read `pkg-r/README.Rmd` to understand the goal of the project, and `README.md` for how the two packages relate.

If you worked in this repository before the two packages were split apart, `MIGRATING.md` covers what moved and what to change in your setup.

Work from the relevant package's directory, not the repository root: `pkg-r/` for R (`devtools::load_all()`, `R CMD check`) and `pkg-py/` for Python (`uv run pytest`, `uv run ruff check`). CI is scoped the same way.

Neither package has been widely adopted or publicly released; changes can be made without a deprecation cycle (or even reference to the way that it used to work).

Use soft wrapping for prose in Markdown files, including skills and vignettes.

Both packages are first-class implementations. Never describe the Python package as a port, translation, or mirror of the R one, in code comments, docstrings, documentation, commit messages, or package metadata. Where one implementation needs to point at the other, name the shared contract that governs them both, or refer to the sibling file plainly.

Anything both implementations must agree on belongs in `tests/shared/` as an executable fixture read by both suites, not as prose and not as a per-language copy. A Python-only or R-only copy of a shared behavior is a review defect. See `tests/shared/README.md`.

This governs behavior a user can observe, not implementation detail. Each package should read idiomatically in its own language, and minor differences between them are fine. Weigh how often a difference would surface and what it costs when it does: a rare one that fails safely is cheaper to accept than to engineer away. See `tests/shared/README.md` for the worked example.

`commons` supports the published table-level `definitions` field in `data-dict.yaml`. Definitions use data-dict's expression language and are compiled to the attached source's SQL dialect. commons temporarily ports the definition-specific export logic until a data-dict R package is available; see [commons #115](https://github.com/posit-dev/commons/issues/115) for the integration design.

When writing tests for either package, refrain from excessive mocking. Instead, prefer testing the real, live path, skipping the test when the needed package or API key isn't available. Broadly, refrain from `expect_match()` for text that is unconditionally included in a prompt or tool description, and `expect_no_match()` for text that has no feasible path to end up in the prompt or tool descriptions.

Release tags are prefixed per package: `r-v*` for the R package, `py-v*` for the Python package.

## Issue tracking with kata (optional)

Work on the Python implementation is tracked in [kata](https://www.katatracker.com/), a local-first issue ledger. `.kata.toml` binds this repository to the `commons` project; the ledger itself is machine-local, so adopting kata is per-developer and entirely optional.

**If `kata --version` does not succeed, skip the rest of this section** — nothing else in this repository depends on it. If it does, treat kata as the system of record for intent and follow the contract below.

<!-- BEGIN KATA (managed by `kata init --with-agents`; condensed from `kata quickstart --format contract`, which prints the canonical version) -->
- Never `kata delete` or `kata purge` without explicit user authorization.
- Search before creating (`kata search`), and prefer commenting on an existing issue over opening a duplicate.
- On claiming or starting an issue, mark it actively tracked: `kata meta set <ref> work.attention ok`. If the work happens on a dedicated branch, stamp it once: `kata meta set <ref> work.branch <branch>`.
- Keep the live signal truthful: `work.attention` is `ok`, `stuck` (cannot proceed), or `needs-human` (want input or review; you may keep working), each with a one-line `work.attention_msg` explaining why. Never end a session with a stale signal: either close the issue or set the pair to reflect the hand-off.
- Closing asserts the work is complete. Close with substantive prose and typed evidence (`kata close <ref> --done --message "..." --commit <sha>`), one issue at a time as each is verified, not in a batch at the end. If it is not done, use `kata label add <ref> needs-review` plus a comment on what remains.
- Parking work: `kata schedule <ref> <date>` when a start date is known, `kata meta set <ref> someday true --json-value` when it is not. Both keep an issue out of `kata ready` and `kata next`.
- Relationships: `--parent` expresses containment and roll-up only and does not gate readiness, though a parent cannot close with open children. Use `--blocks` / `--blocked-by` only for real prerequisites, since those gate `kata ready`. Use `--related` for context.
- Delegating: create each child with `--parent`, `--meta work.branch=...`, and an idempotency key, then join with `kata wait <refs> --until attention --any`. As coordinator you read `work.*` and never write it on issues you delegated.
- One writer per metadata key, and `work.*` on a closed issue is meaningless: never write it there, ignore it when reading.
<!-- END KATA -->

# Cross-language spec fixtures

This directory defines the contracts that govern shared fixtures between the R and Python code.

## The rule

Anything the R and Python implementations must agree on belongs here as a single source. Do not restate the same expectation in the test suite of each language. A hand-maintained per-language copy of a behavior that this directory governs is a review defect because it will drift.

Prose cannot enforce agreement. Every contract added here should be an executable fixture that both suites run, not a description of one.

The rule covers behavior, not implementation. Each package should read idiomatically in its own language, and the two are not expected to match line for line. Before adding a fixture, weigh how often a difference would surface and what it costs when it does.

`normalize_citation()` is the worked example. Each package folds whitespace with its own language's regex, so a quote and a corpus entry differing only by a non-breaking space verify in Python but not in R. That is accepted: the input is uncommon, and the cost is a citation that fails to verify rather than one that verifies wrongly.

## Why this exists

Most Posit R/Python pairs (ellmer/chatlas, ragnar/raghilda, shiny/py-shiny) share concepts and no artifacts. Nothing in them must stay byte-identical. commons is different. Much of its behavior lives in artifacts that must match across languages. The failure mode is invisible. When the system prompt drifts, nothing errors. The agent only behaves differently in one language.

## How each suite consumes these

The Python suite reads this directory directly. The R suite cannot. `testthat` needs its fixtures inside the package, and an installed R package cannot reach files outside its own directory. The R suite reads a copy synced into `pkg-r/tests/testthat/fixtures/shared/`. That copy is committed, `scripts/sync-shared-fixtures.sh` generates it, and a CI job re-runs the script and fails when the copy is stale.

## What belongs here

- **Span names and attributes.** `commons_conversation_turn`, `commons_agent_create`, `commons_data_source_create`, and friends. Also `gen_ai.conversation.id`, `commons.provenance.tag`, and the exact JSON shape of `commons.citation.candidates`. This contract lets the R trajectory reviewer read Python traces. Write it so that it survives the conversation-id ownership moving upstream to shinychat.
- **The provenance and citation behavior.** The `derive_provenance_tag()` truth table, `normalize_citation()` input/output pairs, `match_citation()` verdicts including both guards (10-character minimum, only-the-quote-verifies), `parse_commons_citation()` well-formed and malformed bodies. Also the chunk-invariance cases of the streaming scanner. The scanner is a pure chunks-in/string-out function, so it is ideal fixture material.
- **The citation dialect and display copy.** The `<commons-citation>` grammar and the `PROVENANCE_DISPLAY` strings, so that both UIs say the same words.
- **The definitions interface.** `definitions.json` pins the export-record contract both packages consume, the grain metadata `call_metrics` needs for its mixed-grain guard, and the data-dict problem code each invalid fixture must produce. `definition-export/` is the conformance corpus itself, read by both suites rather than copied into either. `export_records` is generated from the data-dict binary at the pinned commit by `scripts/generate-definitions-fixture.sh`, which refuses to run against a binary built from anything else; `mixed_grain` and `invalid` are hand-maintained and the generator preserves them. This fixture does not replace the conformance harness: the harness compares against a real binary, while this pins what both packages agree to consume.
- **Trace file naming.** `trace(-[0-9]+)?\.jsonl`, one OTLP envelope per line.

## Conventions

Fixtures are JSON. If a case genuinely needs a different format, use that format. Each file carries enough structure for a runner to enumerate the cases without hardcoding them. Land both runners together with the fixture, so the authority claim is real rather than aspirational. A runner that enumerates cases must also assert that the set it enumerated is not empty, because an empty fixture otherwise passes.

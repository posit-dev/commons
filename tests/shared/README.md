# Cross-language spec fixtures

**Status: no fixtures exist yet.** This directory defines the contract that will govern the fixtures. CI enforces nothing here today, and the sync machinery described below is not built. Fixtures will arrive with the provenance and citation code. Each fixture will land together with the runners that read it.

## The rule

Anything the R and Python implementations must agree on belongs here as a single source. Do not restate the same expectation in the test suite of each language. A hand-maintained per-language copy of a behavior that this directory governs will drift is a review defect.

Prose cannot enforce agreement. Every contract added here should be an executable fixture that both suites run, not a description of one.

## Why this exists

Most Posit R/Python pairs (ellmer/chatlas, ragnar/raghilda, shiny/py-shiny) share concepts and no artifacts. Nothing in them must stay byte-identical. commons is different. Much of its behavior lives in artifacts that must match across languages. The failure mode is invisible. When the system prompt drifts, nothing errors. The agent only behaves differently in one language.

## How each suite will consume these

The Python suite can read this directory directly. The R suite cannot. testthat needs its fixtures inside the package, and an installed R package cannot reach files outside its own directory. The R suite will consume a copy synced into `pkg-r/tests/testthat/fixtures/`. That copy is committed, and a CI job re-runs the sync. A stale copy fails the build.

The sync target and the CI job are not built yet. When they land, the rule is: a generated copy is the mechanism, and a hand-edited copy is the defect. The same arrangement is planned for the shared shipped artifacts, the system prompt and the browser assets, for the same reason.

## What belongs here

- **Span names and attributes.** `commons_conversation_turn`, `commons_agent_create`, `commons_data_source_create`, and friends. Also `gen_ai.conversation.id`, `commons.provenance.tag`, and the exact JSON shape of `commons.citation.candidates`. This contract lets the R trajectory reviewer read Python traces. Write it so that it survives the conversation-id ownership moving upstream to shinychat.
- **The provenance and citation behavior.** The `derive_provenance_tag()` truth table, `normalize_citation()` input/output pairs, `match_citation()` verdicts including both guards (10-character minimum, only-the-quote-verifies), `parse_commons_citation()` well-formed and malformed bodies. Also the chunk-invariance cases of the streaming scanner. The scanner is a pure chunks-in/string-out function, so it is ideal fixture material.
- **The citation dialect and display copy.** The `<commons-citation>` grammar and the `PROVENANCE_DISPLAY` strings, so that both UIs say the same words.
- **The definitions interface.** The data-dict CLI JSON contract that both packages consume, plus the grain metadata that `call_metrics` needs for its mixed-grain guard.
- **Trace file naming.** `trace(-[0-9]+)?\.jsonl`, one OTLP envelope per line.

## Conventions

Fixtures are JSON. If a case genuinely needs a different format, use that format. Each file carries enough structure for a runner to enumerate the cases without hardcoding them. Land the R-side runner together with the first fixture. Then the authority claim is real from the start.

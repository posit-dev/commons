# Cross-language spec fixtures

**Status: no fixtures exist yet.** This directory currently defines the contract that will govern them. Nothing here is enforced by CI today, and the sync machinery described below has not been built. Fixtures arrive as the provenance and citation code is ported, each one landing together with the runners that read it.

## The rule

Anything the R and Python implementations must agree on belongs here as a single source, rather than as an expectation restated in each language's test suite. A hand-maintained per-language copy of a behavior governed by this directory is a review defect, not a convenience: the whole reason the directory exists is that such a copy drifts silently.

Prose cannot enforce agreement, so every contract added here has to be an executable fixture that both suites run against, not a description of one.

## Why this exists

Most Posit R/Python pairs (ellmer/chatlas, ragnar/raghilda, shiny/py-shiny) share concepts and no artifacts, so nothing in them has to stay byte-identical. commons is different. Its behavior lives substantially in artifacts that must match across languages, and the failure mode is invisible: when the system prompt drifts, nothing errors, the agent just behaves differently in one language.

## How each suite will consume these

The Python suite can read this directory directly. The R suite cannot, because testthat needs its fixtures inside the package and an installed R package cannot reach files outside its own directory. The R side is therefore intended to consume a copy synced into `pkg-r/tests/testthat/fixtures/`, with that copy committed and a CI job re-running the sync so a stale copy fails the build.

That sync target and CI job are both unbuilt. When they land, the rule to hold is that a generated copy is the mechanism and a hand-edited one is the defect. The same arrangement is planned for the shared shipped artifacts, the system prompt and the browser assets, for the same underlying reason.

## What belongs here

- **Span names and attributes.** `commons_conversation_turn`, `commons_agent_create`, `commons_data_source_create`, and friends; `gen_ai.conversation.id`; `commons.provenance.tag`; and the exact JSON shape of `commons.citation.candidates`. This contract is what lets the R trajectory reviewer read Python traces. Write it so it survives conversation-id ownership moving upstream to shinychat.
- **The provenance and citation behavior.** The `derive_provenance_tag()` truth table, `normalize_citation()` input/output pairs, `match_citation()` verdicts including both guards (10-character minimum, only-the-quote-verifies), `parse_commons_citation()` well-formed and malformed bodies, and the streaming scanner's chunk-invariance cases. The scanner is a pure chunks-in/string-out function, which makes it ideal fixture material.
- **The citation dialect and display copy.** The `<commons-citation>` grammar and the `PROVENANCE_DISPLAY` strings, so both UIs say the same words.
- **The definitions interface.** The data-dict CLI JSON contract both packages consume, plus the grain metadata `call_metrics` needs for its mixed-grain guard.
- **Trace file naming.** `trace(-[0-9]+)?\.jsonl`, one OTLP envelope per line.

## Conventions

Fixtures are JSON unless a case genuinely needs otherwise, and each file carries enough structure that a runner can enumerate cases without hardcoding them. Land the R-side runner together with the first fixture, so the authority claim is real from the start rather than aspirational.

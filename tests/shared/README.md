# Cross-language spec fixtures

Fixtures in this directory are the authority for anything the R and Python implementations of commons must agree on. Both test suites read them directly — `pkg-r/tests/testthat/` and `pkg-py/tests/` — rather than keeping parallel copies of the same expectations. A language-specific copy of a behavior described here is a review defect, not a convenience: the whole reason this directory exists is that a copy drifts silently.

Prose cannot enforce agreement, so each contract here is an executable fixture that CI checks against both implementations.

## Why this exists

Most Posit R/Python pairs (ellmer/chatlas, ragnar/raghilda, shiny/py-shiny) share concepts and no artifacts, so nothing in them has to stay byte-identical. commons is different. Its behavior lives substantially in artifacts that must match across languages, and the failure mode is invisible: when the system prompt drifts, nothing errors, the agent just behaves differently in one language.

## What belongs here

- **Span names and attributes.** `commons_conversation_turn`, `commons_agent_create`, `commons_data_source_create`, and friends; `gen_ai.conversation.id`; `commons.provenance.tag`; and the exact JSON shape of `commons.citation.candidates`. This contract is what lets the R trajectory reviewer read Python traces. Write it so it survives conversation-id ownership moving upstream to shinychat.
- **The provenance and citation behavior.** The `derive_provenance_tag()` truth table, `normalize_citation()` input/output pairs, `match_citation()` verdicts including both guards (10-character minimum, only-the-quote-verifies), `parse_commons_citation()` well-formed and malformed bodies, and the streaming scanner's chunk-invariance cases. The scanner is a pure chunks-in/string-out function, which makes it ideal fixture material.
- **The citation dialect and display copy.** The `<commons-citation>` grammar and the `PROVENANCE_DISPLAY` strings, so both UIs say the same words.
- **The definitions interface.** The data-dict CLI JSON contract both packages consume, plus the grain metadata `call_metrics` needs for its mixed-grain guard.
- **Trace file naming.** `trace(-[0-9]+)?\.jsonl`, one OTLP envelope per line.

## Conventions

Fixtures are JSON unless a case genuinely needs otherwise, and each file carries enough structure that a runner can enumerate cases without hardcoding them. Land the R-side runner together with the first fixture, so the authority claim is real from the start rather than aspirational.

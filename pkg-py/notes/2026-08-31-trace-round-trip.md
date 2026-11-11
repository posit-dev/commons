# Cross-language trace round trip: can R read a Python agent's conversation?

Date: 2026-08-31, revised 2026-09-01 after chatlas 0.22.0.

## The question

Decision D5 keeps the Shiny trajectory reviewer in R through the transition. That only works if R's `commons::trajectory_read()` can read traces a Python agent wrote. The envelope format was already known to match on both sides. What was untested is the layer above it: whether R rebuilds `ellmer::Turn` objects from the way chatlas serializes `gen_ai.input.messages` and `gen_ai.output.messages`.

The answer decides how much of M8 we can defer. If R reads Python traces, the existing reviewer covers Python agents and the largest single piece of work stays on the shelf.

## What was run

A real two-turn chatlas conversation against Ollama `qwen3.6`, with `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` and the `otlp-json-file` exporter writing `trace-1.jsonl`. The second turn calls a registered `row_count` tool, so the trace carries tool calls and tool results as well as plain text. Each turn is wrapped in a `commons_conversation_turn` span with a `commons_provenance` child, which is the span layout `pkg-r/R/tracing.R` produces.

The harness itself is not in the repository: nothing runs it in CI and it needs a local Ollama model. Its source is recorded on the M7 tracing issue, which is where it is needed next, and it should become a test against the tracing module rather than be revived as a script.

R side: `devtools::load_all("pkg-r")` then `trajectory_read()` on the output directory.

Versions: chatlas 0.22.0, opentelemetry-sdk 1.44.0, opentelemetry-exporter-otlp-json-file 0.65b0, R 4.6.1, ellmer 0.4.2, otel 0.2.0.

## Result: the round trip works

R read the Python trace as one conversation of seven turns, in order, with the correct roles:

- The system prompt became a `SystemTurn`, from `gen_ai.system_instructions`.
- Text turns became `UserTurn` and `AssistantTurn` with `ContentText`.
- The tool call became an `AssistantTurn` holding a `ContentToolRequest`, with its id, name and `arguments` list intact.
- The tool result became a `UserTurn` holding a `ContentToolResult` whose value was `4218` and whose `request` slot pointed back at the `row_count` request. chatlas gives tool-result messages the role `tool`, and R maps that to a `UserTurn`, which is how ellmer represents them.
- `commons.provenance.tag` and `commons.citation.candidates` were read from the `commons_provenance` spans and attached to the right exchanges, with the citation decision parsed back to its `quote` / `status` / `label` / `kind` fields.

No change to either package was needed to get this. chatlas' part serialization and R's `semconv_part_content()` are already inverses of each other for the three part types that carry meaning: `text`, `tool_call`, and `tool_call_response`.

The OTLP encoding also lines up without adjustment. The Python file exporter writes camelCase protojson (`traceId`, `parentSpanId`, `startTimeUnixNano`), nanosecond timestamps as strings, and attribute values in `stringValue` / `intValue` form, all of which is what R's `otlp_span()` and `otlp_attributes()` expect. One OTLP envelope per line satisfies R's NDJSON reader, and `trace-1.jsonl` matches its `^(trace(-[0-9]+)?[.]jsonl)$` file pattern.

## The conversation id: upstream now supplies it

R groups spans into conversations with `gen_ai.conversation.id`, read off the **chat** span rather than the wrapper span.

Three upstream changes landed in the week before this spike and together close the gap:

- [chatlas#398](https://github.com/posit-dev/chatlas/pull/398) (merged 2026-08-25, released in **chatlas 0.22.0**) adds a settable `Chat.conversation_id`, recorded as `gen_ai.conversation.id` on the `invoke_agent` and `chat` spans. chatlas never invents an id; unset means the attribute is omitted.
- [ellmer#1106](https://github.com/tidyverse/ellmer/pull/1106) (merged 2026-08-27) adds the matching active binding on the R side.
- [shinychat#343](https://github.com/posit-dev/shinychat/pull/343) (merged 2026-08-28) allocates a stable id per conversation and assigns it to the client in both languages, at first user submission.

So a Python agent sets `chat.conversation_id` and gets the attribute where R looks for it, with no OTel machinery of its own. Verified: chatlas stamps `invoke_agent` and `chat` but not `execute_tool`, which is exactly the set R needs, since it groups on spans where `gen_ai.operation.name == "chat"`.

This also means both packages now reach the attribute the same way, through their own language's client binding, rather than one of them working around a missing feature.

**The failure mode if nothing sets it is silent, so it is worth knowing.** R falls back to the trace id when the chat span has no conversation id, and because each turn's wrapper span is a fresh trace root, every turn becomes its own conversation. Measured rather than reasoned about: with the id on the wrapper span only, two turns read back as two separate conversations, each looking complete and neither reporting an error. In a reviewer that shows up as a conversation list that grows by one entry per message.

Two things follow for M7. The Python dependency floor moves to `chatlas>=0.22.0`, done here, since nothing in `pkg-py` used chatlas yet and the tracing module will. And there is a question to settle rather than assume: when a commons agent runs inside a Shiny app, shinychat is already setting `conversation_id`, so commons should not overwrite it. Setting it unconditionally would relabel a conversation shinychat owns.

## The one divergence, and why it costs nothing

Content types with no GenAI semconv representation serialize as `{"type": "generic", "class": "<ClassName>"}`, and R's part decoder returns `NULL` for them, so they are dropped. With a thinking model this hits every assistant message: `qwen3.6` emitted a `ContentThinking` part alongside the text of every reply, and none of them survived the round trip.

This is not a Python-side divergence. ellmer's own `as_otel_part()` fallback method produces the identical `{"type": "generic", "class": ...}` for any content it has no mapping for, so an R agent using a thinking model loses the same parts when its trace is read back. The behaviour belongs to the shared semconv contract, and both implementations sit on the same side of it.

The cost is bounded. A message keeps its other parts, so an assistant reply that thinks and then answers round-trips its answer. Only a message whose parts are *all* generic decodes to zero contents, and R drops that message entirely. Reasoning text is not something the reviewer displays today, so nothing visible is lost now. Worth revisiting if the reviewer ever wants to show reasoning, at which point the fix belongs in the semconv mapping on both sides, not in either package alone.

## What this settles

- **D5 holds and M8 stays deferred.** The R trajectory reviewer can read Python-agent trajectories, so the UI port is not on the critical path.
- **The conversation-id workaround is not needed.** An earlier revision of this note concluded that commons would have to stamp spans itself with a `SpanProcessor`, because chatlas 0.21.2 had no `conversation_id`. chatlas 0.22.0 supplies it, so M7 sets a property instead.
- **The span and attribute contract is real and untested.** `tests/shared/README.md` already lists span names, `gen_ai.conversation.id`, the `commons.citation.candidates` JSON shape, and the trace file naming as belonging in `tests/shared/`. Nothing pins them yet, and this spike is the evidence that they matter: the conversation-id failure is silent, and a fixture is what would catch it. That extraction belongs with M7, not with this spike.

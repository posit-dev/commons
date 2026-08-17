# Iterate on a commons agent from trajectories

Use this reference when asked to improve an existing `commons` agent from logged trajectories, user feedback, or repeated low-trust answers.

The task is to move recurring questions to the highest appropriate path, increasing trustworthiness and decreasing latency.

```text
Path A: semantic layer
The answer comes from a governed `measure()`. Prefer this for stable, recurring business metrics.

Path B, documented
The answer uses SQL, but the context layer identifies the right table, grain, filters, joins, caveats, or SQL shape. If there are recurring cases in this bucket, consider proposing changes to the semantic layer that would promote those cases into Path A.

Path B, exploratory
The answer uses SQL with little documentation and the agent had to inspect tables, write custom SQL, or make assumptions. Promote recurring cases out of this state.
```

## Workflow

1. Find the agent definition.
   Search for `commons(`, `data_source(`, `semantic_layer(`, `measure(`, and `context_layer(`. Identify where the semantic layer and context layer are constructed. If they are wrapped in project helpers, follow those helpers. Note that measure arguments without `@param` documentation are never seen by the model: an argument named after a data source receives that source's connection, and any other undocumented argument keeps its default. A new measure that queries a database should take the connection this way rather than referencing a global; other objects it needs (a pins board, an API client) should come from a default written as a call, e.g. `board = pins::board_connect()`.

2. Choose the evidence path.
   Do not always begin by loading raw trajectories. First look for a `commons-reviews/` directory or a downloaded review archive.

### Path 1: Reviewed trajectories

Use review documents whenever they are available. They contain the conversations and exchanges a reviewer flagged or annotated, so treat them as the primary qualitative evidence rather than starting over from the raw log.

- Read each `conversation-*.md` file. Parse its YAML frontmatter for the conversation id, active conversation and exchange flags, and reviewer notes. Read the Markdown body for the transcript, trust labels, tool calls, tool results, and notes in context.
- Treat flags as requests for attention, not conclusions. Use review notes to understand what the reviewer wants investigated.
- Treat tool results as excerpts because the Markdown renderer truncates long results.
- Supplement the reviews with raw trajectories only when needed to quantify how common a theme is, inspect a truncated result, or analyze conversations that were not reviewed.

### Path 2: Raw trajectories

When no review documents exist, analyze raw logs now; do not make reviewer setup a prerequisite.

Use `commons::trajectory_read()`. With no arguments it resolves automatically: on Posit Connect it reads this content's own traces, in a deployed project it reads the deployment's traces from Connect, and otherwise it reads local trace files. You can also pass a Connect content GUID, a content URL, or a directory of OTLP trace files. Connect reads require `CONNECT_API_KEY` and editor access to the content.

If resolution is unclear, inspect the project for `log =`, `COMMONS_TRACES_DIR`, `OTEL_*` environment variables, or deployment setup. When the store is large, use `n`, `from`, or `to`, for example:

```r
trajectories <- commons::trajectory_read(
  n = 25,
  from = Sys.Date() - 7
)

turns <- trajectories[[1]]
print(turns)
```

If traces are absent, confirm that the agent runs with `log = TRUE` while OpenTelemetry tracing is active.

### Set up trajectory review

When the project has no review workflow, recommend setting one up for future iterations after completing the current raw-log analysis.

For local review:

```r
commons::trajectory_review(
  commons::trajectory_read() # set n to limit the number of trajectories
)
```

For a deployed reviewer, pass an explicit review directory when durable writable
storage is available:

```r
commons::trajectory_review(
  commons::trajectory_read("<agent-content-guid-or-url>"),
  review_dir = "<path-to-review-directory>"
)
```

Files in a Posit Connect app's working directory are replaced on redeployment. The reviewer can export a `commons-reviews` archive with **Download reviews**. Use one Connect process because separate processes do not coordinate review writes. Prepare local reviewer code when the user asks, but obtain explicit confirmation before deploying content or creating external resources.

3. Analyze themes.
   Group conversations by the business concept being asked about, not by exact wording. Note which themes already hit Path A, which are documented Path B, and which are exploratory Path B.

4. Propose changes.
   Present the highest-value changes first. For each proposal, note the theme and current typical path, how many questions are described by that theme, and the recommended change.

   Prefer semantic-layer edits when the question is a stable governed metric. Prefer context-layer edits when the issue is table choice, grain, filters, joins, caveats, terminology, or reusable SQL shape.

   Classify each proposal the same way the extraction reference does, so the two skills reconcile against existing context identically:
   * **new** — add it.
   * **duplicate** — same concept, same computation: add an `@provenance` tag to the existing measure instead of creating a new one.
   * **extension** — same concept, superset behavior: edit the existing measure, adding the `@param` and the provenance tag. Never create `revenue2`.
   * **conflict** — same concept but a different computation, or a contradiction with an existing dictionary caveat: surface to the user with both sides; do not resolve silently.

5. Wait before editing.
   Do not make semantic-layer or context-layer edits until the user chooses which proposed changes to apply. The data scientist should confirm any new business definition, canonical table, exclusion rule, or SQL pattern.

   When a proposal is accepted, new measures and context land in the agent project layout defined in `SKILL.md`: measures in `measures/`, free-text in `context/`. Because these changes are born from trajectory analysis rather than an artifact, they carry the self-referencing provenance `trajectory analysis (<yyyy-mm-dd>)` — a `#' @provenance` tag on measures, YAML frontmatter on context files.

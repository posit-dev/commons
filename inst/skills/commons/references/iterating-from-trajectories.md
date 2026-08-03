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

2. Load trajectories.
   Use `commons::read_trajectories()`. With no arguments it resolves automatically: on Posit Connect it reads this content's own traces, in a deployed project it reads the deployment's traces from Connect (requires the `CONNECT_API_KEY` environment variable and editor access to the content), and otherwise it reads local trace files. You can also pass a Connect content GUID, a content URL, or a directory of OTLP trace files. If resolution is unclear, inspect the project for `log =`, `COMMONS_TRACES_DIR`, `OTEL_*` environment variables, or deployment setup.

   When the store is large, subset: `n` keeps the `n` most recent conversations, and `from`/`to` keep conversations with chat activity in a time window, e.g. `read_trajectories(n = 25, from = Sys.Date() - 7)`.

3. Load reviews when they are available.
   A trajectory reviewer writes one append-only JSONL file. Read it with
   `read_trajectory_reviews()`, supplying the trajectories so each active flag
   and note is joined to the conversation or exchange it reviews:

```r
reviews <- commons::read_trajectory_reviews(
  Sys.getenv("COMMONS_REVIEW_FILE", "commons-review.jsonl"),
  trajectories
)
```

   The reader removes superseded flag/unflag events. Each returned record is
   therefore either a note or a currently active flag, and its `turns` field
   contains the reviewed conversation or exchange when that trajectory is
   available. Prioritize explicit notes and flagged exchanges during analysis.

4. Read the conversations.
   Each trajectory is a list of ellmer turns, named by conversation id.

```r
trajectories <- commons::read_trajectories()
turns <- trajectories[[1]]

print(turns)
```

5. Analyze themes.
   Group conversations by the business concept being asked about, not by exact wording. Note which themes already hit Path A, which are documented Path B, and which are exploratory Path B.

6. Propose changes.
   Present the highest-value changes first. For each proposal, note the theme and current typical path, how many questions are described by that theme, and the recommended change.

   Prefer semantic-layer edits when the question is a stable governed metric. Prefer context-layer edits when the issue is table choice, grain, filters, joins, caveats, terminology, or reusable SQL shape.

   Classify each proposal the same way the extraction reference does, so the two skills reconcile against existing context identically:
   * **new** — add it.
   * **duplicate** — same concept, same computation: add an `@provenance` tag to the existing measure instead of creating a new one.
   * **extension** — same concept, superset behavior: edit the existing measure, adding the `@param` and the provenance tag. Never create `revenue2`.
   * **conflict** — same concept but a different computation, or a contradiction with an existing dictionary caveat: surface to the user with both sides; do not resolve silently.

7. Wait before editing.
   Do not make semantic-layer or context-layer edits until the user chooses which proposed changes to apply. The data scientist should confirm any new business definition, canonical table, exclusion rule, or SQL pattern.

   When a proposal is accepted, new measures and context land in the agent project layout defined in `SKILL.md`: measures in `measures/`, free-text in `context/`. Because these changes are born from trajectory analysis rather than an artifact, they carry the self-referencing provenance `trajectory analysis (<yyyy-mm-dd>)` — a `#' @provenance` tag on measures, YAML frontmatter on context files.

# Extract commons context from existing data artifacts

Use this reference when asked to turn a trusted, existing data artifact into contributions to a `commons` agent's context. Artifacts in scope are Shiny apps, Quarto reports, plain R scripts, and SQL files — sources whose computations are machine-readable. Non-machine-readable sources (Excel, Confluence) are a separate flow.

The task is to lift the calculations, table knowledge, and prose an artifact already encodes into the agent's semantic layer, dictionaries, and context layer — measures first and foremost. Every contribution carries provenance back to the artifact version it came from, so a maintainer can always trace a definition to its origin.

Extraction assumes an agent project already exists. When creating a new agent,
follow the [onboarding reference](onboarding.md) first; it establishes the
project, scope, and data-source mapping before invoking this workflow.

The user decides which artifacts and calculations are trusted. Do not treat
code as trusted merely because it exists. Do not invent calculations, cleaning,
or transformation logic during extraction. Carry existing trusted logic into
the agent, making only the mechanical changes needed to expose it through
commons. If a required calculation does not already have trusted code, surface
the gap instead of implementing it here.

## Workflow

1. Locate the agent project.
   Find the `commons()` definition and the existing semantic layer, dictionaries (`dictionaries/*.yaml`), and context files. If no agent project is found, say so and stop — this reference does not scaffold one.

2. Inventory the artifact.
   Identify the user-facing outputs and the computation feeding each one:
   * Shiny: each output (`renderText`, `renderPlot`, value boxes, tables) and the reactive subgraph upstream of it (shinymeta-style — follow reactives back to their inputs and data reads).
   * Quarto: each figure, table, and inline computed value, and the chunk that produces it.
   * R scripts / SQL: each result written out, printed, or returned.

   Read the artifact's connection code and attribute each table it queries to one of the agent's `data_source()`s. A table with no corresponding data source is surfaced to the user, not guessed at.

3. Draft measures.
   For each trusted calculation:
   * Inputs the user would vary become documented `@param`s (use the type code spans, e.g. `` `string` ``, `` `enum[EMEA, APAC]` ``).
   * Preserve the computation as the measure body; do not introduce new business, cleaning, or transformation logic.
   * The output's label and surrounding phrasing become the title and description.
   * The data source connection becomes an undocumented argument named after the source (never seen by the model; `commons()` injects the connection). Other objects it needs — a pins board, an API client — come from a default written as a call, e.g. `board = pins::board_connect()`.
   * Record one or more `@provenance` tags (see grammar in `SKILL.md`).

   Preserve hardcoded filters as vetted. Do not speculatively parameterize them; the extension path (step 6) adds parameters later when another artifact or trajectory demands them.

4. Draft dictionary edits.
   Facts the artifact's code teaches about tables and columns — filters always applied, derived columns, caveats in comments, valid value sets — become proposed edits to the matching `dictionaries/*.yaml`. Name the dictionary file after the source. A caveat that comes straight from artifact code can go in a column's `details`.

5. Draft free-text context.
   Knowledge that is neither a callable calculation nor table/column-scoped — methodology prose, business rules, terminology — goes to `context/<artifact>.md`, one file per artifact. Carry the provenance string in YAML frontmatter (`context_layer()` strips frontmatter before indexing, so it never reaches the model).

6. Reconcile against existing context.
   Classify each candidate against what the agent already has:
   * **new** — add it.
   * **duplicate** — same concept, same computation: add an `@provenance` tag to the existing measure instead of creating a new one.
   * **extension** — same concept, superset behavior (e.g. adds a filter parameter): propose editing the existing measure, adding the `@param` and the provenance tag. Never create `revenue2`.
   * **conflict** — same concept but a different computation, or a contradiction with an existing dictionary caveat: surface to the user with both sides. Do not resolve silently.

7. Wait before editing.
   Present proposals highest-value first (mirroring the iterate reference) and apply only what the user confirms. The data scientist should confirm any new business definition, canonical table, exclusion rule, or dictionary caveat.

8. Validate.
   Confirm `semantic_layer("measures/")` loads without error. Fidelity validation — running extracted measures against the live source and comparing to the artifact's rendered output — is out of scope.

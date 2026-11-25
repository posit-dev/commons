# Extract commons context from existing data artifacts

## Contents

- [Purpose and boundaries](#purpose-and-boundaries)
- [Workflow](#workflow)

## Purpose and boundaries

Use this reference when asked to turn a trusted, existing data artifact into contributions to a `commons` agent's context. Artifacts in scope are Shiny apps, Quarto reports, Jupyter notebooks, plain Python scripts, and SQL files — sources whose computations are machine-readable. Non-machine-readable sources (Excel, Confluence) are a separate flow.

The task is to lift the calculations an artifact already encodes into measures or governed definitions, and its table knowledge and prose into dictionaries and the context layer. Every contribution carries provenance back to the artifact version it came from, so a maintainer can always trace a definition to its origin.

Extraction assumes an agent project already exists. When creating a new agent, follow the [onboarding reference](onboarding.md) first; it establishes the project, scope, and data source mapping before invoking this workflow.

The user decides which artifacts and calculations are trusted. Do not treat code as trusted merely because it exists. Do not invent calculations, cleaning, or transformation logic during extraction. Carry existing trusted logic into the agent, making only the mechanical changes needed to expose it through commons. If a required calculation does not already have trusted code, surface the gap instead of implementing it here.

## Workflow

1. Locate the agent project. Find the `commons.Commons()` construction and the existing semantic layer, dictionaries (`dictionaries/*.yaml`), and context files. If no agent project is found, say so and stop — this reference does not scaffold one.

2. Establish runnable access. Treat extraction as a code-running workflow, not a static source review. Confirm access to the artifact, each data source it uses, and its runtime dependencies. Use the project's existing authentication and configuration mechanisms. If credentials are missing, ask the user to provide authorized, preferably read-only access through an appropriate secret-management mechanism. Never write credential values to the agent project, agent instruction files, proposals, or logs.

   Run the artifact or representative computation paths to verify that connections succeed, dependencies load, and the trusted code still works. If execution is not possible, surface the limitation and do not present conclusions from static inspection as verified.

3. Inventory the artifact. Identify the user-facing outputs and the computation feeding each one:
   - Shiny: each output (`@render.text`, `@render.plot`, `@render.data_frame`, value boxes) and the reactive graph upstream of it (follow `@reactive.calc` and `@reactive.effect` functions back to their inputs and data reads).
   - Quarto and Jupyter: each figure, table, and inline computed value, and the cell that produces it. In a notebook, check that the cells still run in order; out-of-order execution can leave outputs no fresh run reproduces.
   - Python scripts / SQL: each result written out, printed, or returned.

   Exercise representative outputs and inputs while tracing their computation. Read the artifact's connection code and attribute each table it queries to one of the agent's `data_source()`s. Verify the mapping by running the relevant code. A table with no corresponding data source is surfaced to the user, not guessed at.

4. Draft semantic layer contributions. For each trusted calculation, propose either a measure or a governed definition rather than representing the same calculation in both places. Consider a governed definition when the artifact contains a reusable SQL expression scoped to one table; otherwise, default to a measure. Follow the [data dictionary reference](data-dictionaries.md) when proposing a definition.

   For each proposed measure:
   - Inputs the user would vary become model-supplied parameters, annotated `Annotated[T, Field(description=...)]`. Use the narrowest type, e.g. `str`, `int`, or `Literal["EMEA", "APAC"]`.
   - Preserve the computation as the measure body; do not introduce new business, cleaning, or transformation logic.
   - The output's label and surrounding phrasing become the title (`title=`, or the humanized function name) and the description (the docstring, or `description=`).
   - The data source connection becomes a `commons.Injected[...]` parameter named after the source (never seen by the model; the agent injects the connection). Other objects it needs — a pins board, an API client — come from an injected parameter that defaults to `None` and is built inside the measure when absent, e.g. `board = board or pins.board_connect()`, so nothing connects when the module is imported.
   - Record one or more strings in `provenance=[...]` (see grammar in `SKILL.md`).

   Preserve hardcoded filters as vetted. Do not speculatively parameterize them; the extension path (step 7) adds parameters later when another artifact or trajectory demands them.

5. Draft dictionary edits. Put proposed governed definitions in the matching table's `definitions`. Facts the artifact's code teaches about tables and columns — filters always applied, derived columns, caveats in comments, valid value sets — become proposed edits to the matching `dictionaries/*.yaml`. Name the dictionary file after the source. A caveat that comes straight from artifact code can go in a column's `details`.

   Follow the [data dictionary reference](data-dictionaries.md) for placement, source mapping, governed definitions, and commons-specific validation.

6. Draft free-text context. Knowledge that is neither a callable calculation nor table/column-scoped — methodology prose, business rules, terminology — goes to `context/<artifact>.md`, one file per artifact. Carry the provenance string in YAML frontmatter (`context_layer()` strips frontmatter before indexing, so it never reaches the model).

7. Reconcile against existing context. Two measures are the same concept if their results mean the same thing, even if their names differ. Compare each candidate with existing measures and definitions that read the same tables or answer a similar question, running both where they overlap. Classify each candidate against what the agent already has:
   - **new** — add it.
   - **duplicate** — same concept, same computation: do not create another contribution. For a measure, add a `provenance` entry to the existing measure.
   - **extension** — same concept, superset behavior: propose editing the existing contribution. For a measure, add the relevant parameters and `provenance` entries. Never create `revenue2`.
   - **conflict** — same concept but a different computation, or a contradiction with an existing dictionary caveat: surface to the user with both sides. Do not resolve silently.

8. Wait before editing. Present proposals highest-value first (mirroring the iterate reference) and apply only what the user confirms. For each proposed measure, say briefly how it relates to the closest existing measures. The data scientist should confirm any new business definition, canonical table, exclusion rule, or dictionary caveat.

9. Validate. Confirm `commons.semantic_layer("measures")` loads without error. Validate dictionary edits and governed definitions using the [data dictionary reference](data-dictionaries.md).

   Run each accepted measure and governed definition against the live source with representative inputs. Compare its value, shape, grouping, filtering, and missing-value behavior with the original artifact computation. Resolve mismatches before treating extraction as complete. If the original and extracted computations cannot both be run, record that fidelity remains unverified.

   Then check that the agent reaches for each accepted measure: ask a fresh agent one or two questions a human user might ask—briefly and without naming the measure—and look in `agent.get_turns()` for a `call_measure` tool request naming it. If the agent misses it, improve the measure's documentation, not by adding wording that only matches the test question. When extracting as part of onboarding, wait until the agent is built in onboarding step 10 to run this check.

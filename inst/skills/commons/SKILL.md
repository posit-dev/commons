---
name: commons
description: >-
  Build, maintain, and iterate on self-service data agents with commons. Use
  when onboarding a new agent, creating or reviewing data dictionaries,
  extracting trusted calculations and context from existing artifacts,
  evaluating an agent, or improving one from logged trajectories.
---

# commons

Read the relevant reference below before starting the corresponding task.

- [Onboarding](references/onboarding.md) - onboard and create a commons agent from existing materials.
- [Use data dictionaries with commons](references/data-dictionaries.md) - read alongside onboarding or extraction when creating, reviewing, or editing a data dictionary.
- [Extract commons context from existing data artifacts](references/extracting-from-artifacts.md) - turn a trusted Shiny app, Quarto report, R script, or SQL file into measures, governed definitions, dictionary edits, and free-text context, each carrying provenance back to its source.
- [Evaluating a commons agent](references/evaluation.md) - create an evaluation for a commons agent to determine whether it is working correctly.
- [Iterate on a commons agent from trajectories](references/iterating-from-trajectories.md) - improve an existing agent from reviewed conversations when available, or from raw logged trajectories otherwise, then propose semantic-layer or context-layer changes.

## Working principles

* Aim for a solid data foundation, but not perfection. The data should be
  trustworthy and have a reasonably solid creation process, but it can continue to improve after the agent is built.
* Give the agent data that is fine-grained enough for custom manipulation, but trusted and cleaned enough that it will not make unforced errors or need context that reasonably belongs in the data preparation process.
* Keep context DRY. Information in a data dictionary, for example, should not also appear in free text in the context layer.
* Verify anything that can be verified.
* Preserve provenance. Everything that can be cited should be cited.
* Never fabricate information or pull from general knowledge without the
  user's permission. Include only scope-relevant information from approved
  sources.
* Surface uncertainties and contradictions instead of resolving them silently.

## Agent project layout

A commons agent project follows this on-disk convention. The onboarding,
extraction, and trajectory references build on it.

```
my-agent/
├── agent.R                  # commons() definition
├── DESCRIPTION
├── instructions.md          # optional concise, always-needed guidance
├── onboarding.md            # scope, decisions, and unresolved questions
├── dictionaries/
│   └── warehouse.yaml       # one data-dict.yaml per data_source(), named
│                            # to match the source name in the commons() call
├── measures/
│   ├── sales-dashboard.R    # measures grouped by source artifact (default
│   └── churn-report.R       # landing spot only; reorganizing later is safe)
└── context/
    ├── sales-dashboard.md   # free-text context, one file per artifact
    └── churn-report.md
```

## Provenance

Every contribution points back to the source it came from with a machine-parseable string. When the host offers a commit-pinned permalink to a line range, use it directly — it is clickable and pins the same repo, sha, path, and lines in one token:

```
https://github.com/org/sales-dashboard/blob/abc1234/R/server.R#L120-L145
```

For hosts without a permalink convention (a bare git remote, an internal server), fall back to the host-agnostic grammar:

```
<repo-url>@<sha> <path>#L<start>-L<end>
```

For artifacts not under version control, prefer a stable URL that identifies the source (e.g. a published report or deployed app) over a local path; either way, use `<location> (retrieved <yyyy-mm-dd>)`, where `<location>` is that URL or, failing that, a local path. Measures born from the iterate skill rather than an artifact self-reference their origin: `trajectory analysis (<yyyy-mm-dd>)`.

Where each kind of contribution carries it:

* Measures: one or more `#' @provenance` roxygen tags per measure. The tag never reaches the model — `read_measures()` forwards only the title, description, `@return`, and documented `@param`s.
* Context files: the same string in YAML frontmatter. `context_layer()` strips frontmatter before indexing, so it never reaches the model.
* Dictionary edits: git commit messages; optionally a column's `details` when a caveat comes straight from artifact code.

Example extracted measure:

```r
#' Quarterly revenue
#'
#' Revenue for a fiscal quarter as reported in the sales dashboard's
#' "Revenue (QTD)" value box. Excludes tax and intra-company transfers.
#'
#' @param quarter `string` Fiscal quarter, e.g. "2026 Q2".
#' @provenance https://github.com/org/sales-dashboard/blob/abc1234/R/server.R#L120-L145
#' @measure
quarterly_revenue <- function(quarter, warehouse) {
  ...
}
```

---
name: commons
description: Building, maintaining, and iterating on a self-service data agent with commons.
---

# commons

Read the relevant reference below before starting the corresponding task.

- [Extract commons context from existing data artifacts](references/extracting-from-artifacts.md) - turn a trusted Shiny app, Quarto report, R script, or SQL file into measures, dictionary edits, and free-text context, each carrying provenance back to its source.
- [Iterate on a commons agent from trajectories](references/iterating-from-trajectories.md) - improve an existing agent by reading logged trajectories, finding recurring low-trust or slow answers, and proposing semantic-layer or context-layer changes.

## Agent project layout

A commons agent project follows this on-disk convention. Both references above build on it.

```
my-agent/
├── agent.R                  # commons() definition
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

Every contribution points back to the source it came from with a machine-parseable string. The grammar:

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
#' @provenance github.com/org/sales-dashboard@abc1234 R/server.R#L120-L145
#' @measure
quarterly_revenue <- function(quarter, warehouse) {
  ...
}
```

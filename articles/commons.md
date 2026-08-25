# Introduction to commons

This document explains the structure of a commons project and how to
start building a commons agent.

``` r

library(commons)
```

## Design philosophy

AI agents for data analysis can range from overly cautious and narrowly
correct to wildly untrustworthy. commons increases the likelihood of
correct answers by providing agents with access to existing trusted
code, while still allowing them enough flexibility to answer novel,
realistic questions. commons also labels answers with trust tags based
on the analysis path so that users can determine how much trust to put
in a given answer.

If you are a data analyst, data scientist, statistical programmer, or
other data practitioner, you likely have a collection of “trusted” code.
This is code that you depend on for your analyses and use to create
apps, reports, and packages. The core idea behind commons is that we can
improve an agent’s correctness by giving it the right access and
documentation to run this code.

The high-trust “happy path” occurs when the user asks a question that
corresponds to one of these **trusted calculations**. For example, say
we have a commons agent that can analyze biodiversity data. The user
asks:

> How many total animals were observed at Oak Bluff?

The agent then searches for a trusted calculation that can answer the
question. If it finds one, it runs that code and then reports the result
along with a “Verified answer” tag.

> At Oak Bluff, 59 individual animals were observed across 5 species,
> based on 28 hours of survey effort. Note this reflects observed
> individuals during surveys, not necessarily a full census of every
> animal present at the site.
>
> ![Verified answer](commons-icons/trusted-icon.svg)Verified answer This
> answer comes from a governed calculation defined by your data team.

Although the agent had to decide which trusted calculation to run, it
did not have to decide *what code to write*, reducing degrees of freedom
and allowing it to take advantage of pre-vetted code.

However, we also expect users to ask questions that stray from the
“happy path.” For those, the agent searches for additional context and
writes custom code (either SQL or R). Answers from this path either
include a verified citation or are tagged as `Untrusted`.

## Working with the agent skill

The package includes a commons [agent skill](https://agentskills.io/)
that helps coding agents build, evaluate, and improve commons agents. We
recommend installing it before you begin because it provides detailed
guidance and a structured workflow.

To make the skill available to **Posit Assistant or Codex**, copy the
skill and its references to `.agents/skills`:

``` r

skill <- system.file("skills", "commons", package = "commons")
dir.create(".agents/skills", recursive = TRUE, showWarnings = FALSE)
file.copy(skill, ".agents/skills", recursive = TRUE)
```

For **Claude Code**, copy the skill and its references to
`.claude/skills`:

``` r

skill <- system.file("skills", "commons", package = "commons")
dir.create(".claude/skills", recursive = TRUE, showWarnings = FALSE)
file.copy(skill, ".claude/skills", recursive = TRUE)
```

## Trust flow

commons agents will use trusted calculations whenever possible. When the
user asks a question, the agent first searches the semantic layer for a
trusted calculation. If it finds one, it then calls that calculation and
the resulting answer is tagged with a green verified answer pill.

If a relevant trusted calculation is not found, the agent proceeds down
the lower trust path. It searches through the context for additional
information, then uses that information to write custom SQL or R code to
answer the user’s question. These answers either include a verified
citation in a footnote or are tagged as `Untrusted`.

Search trusted  
calculations

→ →

High trust

Relevant calculation  
found → Run trusted  
calculation → ![Verified answer](commons-icons/trusted-icon.svg)Verified
answer This answer comes from a governed calculation defined by your
data team.

Lower trust

No relevant  
calculation found → Search  
context → Write  
SQL/R → Cited answer¹ or
![Untrusted](commons-icons/warning-icon.svg)Untrusted This answer was
not produced by a governed calculation and has no verified supporting
citation. AI can be wrong.

There are two possible trust outcomes for the “lower trust” path. When
the agent writes custom SQL or R, it can also include supporting text
quoted from a trusted source. commons verifies that the quoted text
appears in that source. Verified citations are displayed as footnotes.
If the agent does not include a citation, or if commons can’t verify any
of its citations, the answer gets tagged as `Untrusted`.

The following table details the various ways each trust outcome can
occur:

| How the answer is produced | Outcome |
|----|----|
| A trusted R [measure](#semantic-layer) |  ![Verified answer](commons-icons/trusted-icon.svg)Verified answer This answer comes from a governed calculation defined by your data team. |
| A [data-dictionary metric](#definitions), possibly grouped or filtered with [definitions](#data-dictionaries) |  ![Verified answer](commons-icons/trusted-icon.svg)Verified answer This answer comes from a governed calculation defined by your data team. |
| A [Snowflake semantic-view or Databricks metric-view metric](#warehouse-semantic-layers) |  ![Verified answer](commons-icons/trusted-icon.svg)Verified answer This answer comes from a governed calculation defined by your data team. |
| Custom SQL, including SQL that uses [data-dictionary definitions](#definitions) | Cited or  ![Untrusted](commons-icons/warning-icon.svg)Untrusted This answer was not produced by a governed calculation and has no verified supporting citation. AI can be wrong. |
| Custom R | Cited or  ![Untrusted](commons-icons/warning-icon.svg)Untrusted This answer was not produced by a governed calculation and has no verified supporting citation. AI can be wrong. |
| No data tool used (e.g., because the agent already had sufficient information or the question could not be answered from accessible information) | No label |

The agent itself does not tag the answer as verified, cited, or
untrusted. This process is instead handled deterministically by the
commons package based on the agent’s behavior.

## Information layers

commons distinguishes between two primary layers of information: the
**semantic layer** and the **context layer**. The semantic layer encodes
trusted calculations, ideally lifted from reliable code that you already
use. The **context layer** contains background or supporting
information, useful both for figuring out what custom code to run and
how to interpret results. Data dictionaries span the two layers.

| Layer | Sources | Role |
|----|----|----|
| Semantic layer | Measures in `.R` files, [`definitions`](#definitions) in `data-dict.yaml`, and supported [warehouse semantic models](#warehouse-semantic-layers) | Provides trusted calculations. |
| Context layer | Markdown files and descriptive fields in [`data-dict.yaml`](#data-dictionaries) | Informs custom SQL or R and guides interpretation. |

### Semantic layer

There are multiple ways to add information to the semantic layer.
Probably the most straightforward way is as **measures** stored in `.R`
files. Measures are R functions documented with roxygen2 and marked with
`@measure`. When measures are available, the agent will search for a
measure relevant to the user’s question. If it finds one, it calls that
measure, possibly supplying arguments.

`data-dict.yaml` files can also contribute to the semantic layer through
[`definitions`](#definitions). See [Data
dictionaries](#data-dictionaries) for more information. Supported
warehouse semantic models can also provide trusted calculations.

### Context layer

The context layer draws from unstructured information in Markdown files
and the descriptive fields in `data-dict.yaml`.

### Examples

Here are brief examples of a data dictionary, a measure file, and a
context-layer Markdown file for the biodiversity example app:

#### Data dictionary

`dictionaries/biodiversity.yaml`

``` yaml
tables:
  - name: observations
    description: Species observations by nature preserve.
    columns:
      - name: count
        description: Individuals observed during surveys.
```

#### Measure file

`measures/biodiversity.R`

``` r

#' Species richness by site
#'
#' @param site `string` Site name.
#' @measure
biodiversity_by_site <- function(biodiversity, site) {
  dplyr::tbl(biodiversity, "observations") |>
    dplyr::filter(obs_site == site) |>
    dplyr::summarize(
      species_richness = dplyr::n_distinct(species)
    )
}
```

#### Context document

`context/biodiversity.md`

``` markdown
# Interpreting survey results

Observed individuals reflect organisms recorded during surveys. They should not be interpreted as a complete population census of a nature preserve.
```

### Warehouse semantic layers

If you have trusted metrics in [Snowflake semantic
views](https://docs.snowflake.com/en/user-guide/views-semantic/overview)
or [Databricks metric
views](https://docs.databricks.com/aws/en/uc-semantics/metric-views),
you can use those calculations directly with commons. It can also group
or filter metrics by approved fields from the warehouse. Answers based
on these warehouse-defined metrics are marked as verified.

## Data sources

One of the primary decisions you’ll need to make when building a commons
agent is which data sources to grant the agent access to. Each data
source combines the underlying data with the tables to expose to the
agent. It can also include a data dictionary describing those tables and
trusted calculations on them.

Create a data source with
[`data_source()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/data_source.md).
The underlying data can consist of named data frames, a
[pins](https://pins.rstudio.com/) board, or a DBI connection. Data
frames and pins boards will be loaded into an in-process DuckDB
database. Database connections will be queried directly.

For example, the following code creates a data source from two data
frames. Each name becomes a table available to the agent. `dictionary`
is an optional path to a `data-dict.yaml` file.

``` r

biodiversity <- data_source(
  observations = observations,
  site_area = site_area,
  dictionary = "dictionaries/biodiversity.yaml"
)
```

### Data dictionaries

Data dictionaries provide structured, source-specific documentation for
a data source. Use a data dictionary to specify what each table
represents, column meanings and types, relationships between tables,
glossary terms, and trusted `definitions`. commons supports the
[`data-dict.yaml` specification](https://data-dict.tidyverse.org/).

commons agents use data dictionaries in a few ways:

- Dataset-level descriptions and details provide broad, always-available
  context. Glossary terms are included in the system prompt as space
  allows.
- The first time the agent uses a documented table in a conversation, it
  receives the table’s description, column information, relationships,
  and relevant glossary terms.
- Descriptive fields (including `description` and `details`) are
  available to the agent as part of the context layer.

#### Definitions

**Definitions** are named, governed expressions attached to tables in
`data-dict.yaml`. They allow an agent to reuse trusted metrics, filters,
and derived values, contributing to the semantic layer.

Each definition is an expression written in [data-dict’s expression
language](https://data-dict.tidyverse.org/expressions.html), not in your
database’s SQL dialect:

``` yaml
tables:
  - name: observations
    columns:
      - name: count
        type: number
    definitions:
      - name: total_individuals
        label: Total individuals observed
        description: Sum of the individuals recorded in surveys.
        expr: SUM(count)
```

There are three kinds of definitions. Definitions can participate in
trusted metric calculations or be used in custom SQL:[^1]

| Kind | Example | Use in `call_metrics()` |
|----|----|----|
| Metric | `SUM(n)` | Computes the metric |
| Filter | `status = 'active'` | Restricts rows or provides a grouping dimension |
| Derived value | `price * quantity` | Provides a grouping dimension |

commons infers the definition kind from its expression. Aggregate and
constant expressions are categorized as metrics, row-level Boolean
expressions as filters, and other row-level expressions as derived
values.

See the [DevRel Agent
`data-dict.yaml`](https://github.com/posit-dev/devrel-agent/blob/main/dictionaries/devrel.data-dict.yaml)
for examples of definitions.

When a data source is constructed, commons validates each definition and
compiles it to the source’s SQL dialect.

## Project directory organization

A commons agent is easiest to maintain when the pieces live in separate
files:

``` text
.
|-- app.R
|-- agent.R
|-- DESCRIPTION
|-- AGENTS.md # or your coding agent's equivalent (e.g., CLAUDE.md)
|-- instructions.md
|-- dictionaries/
|   `-- biodiversity.yaml
|-- measures/
|   `-- measures.R
`-- context/
    `-- context.md
```

## Constructing the agent

Use
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
to construct an agent. Pass it an ellmer `Chat` and one or more data
sources, along with any semantic and context layers. You can also
optionally append information to the commons agent system prompt using
the `instructions` argument.

``` r

library(commons)

biodiversity <- data_source(
  observations = observations,
  site_area = site_area,
  dictionary = "dictionaries/biodiversity.yaml"
)

agent <- commons(
  client = ellmer::chat("anthropic/claude-sonnet-5"),
  data_sources = list(biodiversity = biodiversity),
  semantic_layer = semantic_layer("measures"),
  context_layer = context_layer("context/context.md"),
  instructions = "instructions.md"
)

commons_app(agent)
```

Use
[`commons_app()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons_app.md)
to run the agent in a local or single-user Shiny app. For multi-user
deployments, use
[`commons_ui()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons_app.md)
and
[`commons_server()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons_app.md)
and create a new agent for each Shiny session. This example assumes that
`observations` and `site_area` are data frames loaded when the app
starts.

[^1]: In custom SQL, the agent refers to a definition using its
    `{{name}}` token. commons expands the token to SQL compiled for the
    data source. Because this is still custom SQL, the answer includes a
    verified citation or is tagged as `Untrusted`, rather than
    `Verified`.

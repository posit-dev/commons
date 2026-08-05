# Create a commons agent

`commons()` creates an
[ellmer::Chat](https://ellmer.tidyverse.org/reference/Chat.html)
subclass with tools for a semantic layer, context search, table
inspection, and SQL queries.

## Usage

``` r
commons(
  client = ellmer::chat_anthropic(),
  data_sources,
  semantic_layer = NULL,
  context_layer = NULL,
  ...,
  system_prompt = system.file("prompts/system-prompt.md", package = "commons"),
  network = c("none", "full"),
  log = FALSE,
  share_with = NULL
)
```

## Arguments

- client:

  An [ellmer::Chat](https://ellmer.tidyverse.org/reference/Chat.html)
  giving the provider and model to use, e.g.
  [`ellmer::chat_anthropic()`](https://ellmer.tidyverse.org/reference/chat_anthropic.html).
  A system prompt already set on the client is ignored, with a warning;
  use `system_prompt` instead.

- data_sources:

  A
  [`data_source()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/data_source.md),
  or a named list of them. Measures can take a source's connection as an
  argument named after the source; see
  [`semantic_layer()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/semantic_layer.md).
  When there are several sources, the `run_sql` and `describe_table`
  tools take a source's name as a `source` argument.

- semantic_layer:

  An optional
  [`semantic_layer()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/semantic_layer.md).

- context_layer:

  An optional
  [`context_layer()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/context_layer.md).

- ...:

  These dots are for future extensions and must be empty.

- system_prompt:

  The agent's system-prompt template, as a single string containing the
  template or the path to a template file. The default uses the markdown
  prompt shipped with commons. To customize the full prompt, copy that
  file into your project, edit it freely, and pass its path:

      file.copy(
        system.file("prompts/system-prompt.md", package = "commons"),
        "system-prompt.md"
      )
      commons(
        # ...
        system_prompt = "system-prompt.md"
      )

  commons renders some sections conditionally and interpolates runtime
  values such as its table roster. Custom templates may edit, remove, or
  reposition any section. Commons expressions open with `{[` and close
  with `]}`, leaving ellmer's `{{ }}` delimiters available for your own
  substitutions:

      system_prompt <- ellmer::interpolate_file(
        "system-prompt.md",
        organization = "Acme"
      )
      commons(
        # ...
        system_prompt = as.character(system_prompt)
      )

  A `{{organization}}` expression is resolved by ellmer, while commons'
  template expressions remain untouched.

- network:

  Whether the `run_r` session has network access. One of `"none"` (the
  default) or `"full"`. The session requires Linux or macOS and refuses
  to run without filesystem sandboxing.

- log:

  Whether to capture conversation trajectories with OpenTelemetry
  (default `FALSE`). When `TRUE`, commons enables GenAI message-content
  capture in ellmer and tags each turn's spans with a conversation id;
  the spans go wherever OTel is configured to export. On Posit Connect,
  traces land in Connect's observability store (browsable in its Trace
  Viewer); commons switches on the content's *Content Observability*
  setting itself when needed, though capture only starts once the
  content restarts. Locally, commons configures otelsdk's file exporter
  automatically when no exporter is set up. Read trajectories back with
  [`trajectory_read()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/trajectory_read.md).

- share_with:

  An optional character vector of Connect usernames granted access to
  this content's trajectories when running on Posit Connect. Reading
  traces requires editor-level access, so named users are added as
  collaborators on the content. Note that users whose Connect *account*
  role is viewer cannot read traces even when named here; trace readers
  need at least a publisher account.

## Value

An [ellmer::Chat](https://ellmer.tidyverse.org/reference/Chat.html)
subclass.

## Details

The provider and model come from `client`; commons sets its own system
prompt and tools. Use `agent$chat()` to ask questions,
[`commons_ui()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons_ui.md)
and
[`commons_server()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons_ui.md)
to embed the agent in Shiny, and
[`vitals::generate()`](https://vitals.tidyverse.org/reference/generate.html)
to use the agent as a vitals solver.

## Examples

``` r
if (FALSE) { # \dontrun{
# A measure over local data computes directly in R.
sem <- semantic_layer(
  measure(
    "order_count",
    "Count of orders.",
    function() nrow(my_sales),
    arguments = list()
  )
)
agent <- commons(
  ellmer::chat_anthropic(),
  data_sources = data_source(sales = my_sales),
  semantic_layer = sem
)
agent$chat("How many orders are there?")

# A measure takes a connection as an argument named after a data source.
# `warehouse` isn't in `arguments`, so the model never sees it; commons
# supplies it when the measure runs. Interpolate model-supplied arguments
# with glue::glue_sql() so they're quoted safely.
con <- DBI::dbConnect(duckdb::duckdb())
sem <- semantic_layer(
  measure(
    "revenue_by_region",
    "Total revenue for a region.",
    function(region, warehouse) {
      DBI::dbGetQuery(
        warehouse,
        glue::glue_sql(
          "SELECT sum(revenue) AS revenue FROM sales WHERE region = {region}",
          .con = warehouse
        )
      )
    },
    arguments = list(region = ellmer::type_string("Sales region."))
  )
)
agent <- commons(
  ellmer::chat_anthropic(),
  data_sources = list(warehouse = data_source(con)),
  semantic_layer = sem
)

# Objects that aren't data sources (a pins board, an API client) come from
# argument defaults in the measure, e.g. `board = pins::board_connect()`.
# See ?semantic_layer.
} # }
```

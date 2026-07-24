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
  context_layer = NULL,
  semantic_layer = NULL,
  system_prompt = ellmer::interpolate_file(system.file("prompts/system-prompt.md",
    package = "commons"), date = Sys.Date()),
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

- context_layer:

  An optional
  [`context_layer()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/context_layer.md).

- semantic_layer:

  An optional
  [`semantic_layer()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/semantic_layer.md).

- system_prompt:

  The agent's system prompt, as a single string. The default
  interpolates the markdown prompt shipped with commons, filling its
  `{{date}}` keyword. To customize the prompt, copy that file into your
  project, edit freely, and interpolate it yourself:

      file.copy(
        system.file("prompts/system-prompt.md", package = "commons"),
        "system-prompt.md"
      )
      commons(
        # ...
        system_prompt = ellmer::interpolate_file(
          "system-prompt.md",
          date = Sys.Date()
        )
      )

  Pass values for any `{{keyword}}` tokens you add as arguments to
  [`ellmer::interpolate_file()`](https://ellmer.tidyverse.org/reference/interpolate.html).
  commons appends documentation of the available tables and data
  dictionaries to the prompt itself; the file needn't (and shouldn't)
  describe them.

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
  [`read_trajectories()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/read_trajectories.md).

- share_with:

  An optional character vector of Connect usernames granted access to
  this content's trajectories when running on Posit Connect. Reading
  traces requires editor-level access, so named users are added as
  collaborators on the content. Note that users whose Connect *account*
  role is viewer cannot read traces even when named here; trace readers
  need at least a publisher account.

## Value

A `Commons` object, which subclasses
[ellmer::Chat](https://ellmer.tidyverse.org/reference/Chat.html).

## Details

The provider and model come from `client`; commons sets its own system
prompt and tools. Use `agent$chat()` to ask questions,
[`commons_ui()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons_ui.md)
and
[`commons_server()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons_ui.md)
to embed the agent in Shiny, and
[`vitals::generate()`](https://vitals.tidyverse.org/reference/generate.html)
to use the agent as a vitals solver.

## Super class

[`ellmer::Chat`](https://ellmer.tidyverse.org/reference/Chat.html) -\>
`Commons`

## Methods

### Public methods

- [`Commons$new()`](#method-Commons-initialize)

- [`Commons$chat()`](#method-Commons-chat)

- [`Commons$stream_async()`](#method-Commons-stream_async)

- [`Commons$citation_corpus()`](#method-Commons-citation_corpus)

- [`Commons$prewarm()`](#method-Commons-prewarm)

- [`Commons$clone()`](#method-Commons-clone)

Inherited methods

- [`ellmer::Chat$add_turn()`](https://ellmer.tidyverse.org/reference/Chat.html#method-add_turn)
- [`ellmer::Chat$chat_async()`](https://ellmer.tidyverse.org/reference/Chat.html#method-chat_async)
- [`ellmer::Chat$chat_structured()`](https://ellmer.tidyverse.org/reference/Chat.html#method-chat_structured)
- [`ellmer::Chat$chat_structured_async()`](https://ellmer.tidyverse.org/reference/Chat.html#method-chat_structured_async)
- [`ellmer::Chat$get_cost()`](https://ellmer.tidyverse.org/reference/Chat.html#method-get_cost)
- [`ellmer::Chat$get_model()`](https://ellmer.tidyverse.org/reference/Chat.html#method-get_model)
- [`ellmer::Chat$get_provider()`](https://ellmer.tidyverse.org/reference/Chat.html#method-get_provider)
- [`ellmer::Chat$get_system_prompt()`](https://ellmer.tidyverse.org/reference/Chat.html#method-get_system_prompt)
- [`ellmer::Chat$get_tokens()`](https://ellmer.tidyverse.org/reference/Chat.html#method-get_tokens)
- [`ellmer::Chat$get_tools()`](https://ellmer.tidyverse.org/reference/Chat.html#method-get_tools)
- [`ellmer::Chat$get_turns()`](https://ellmer.tidyverse.org/reference/Chat.html#method-get_turns)
- [`ellmer::Chat$last_turn()`](https://ellmer.tidyverse.org/reference/Chat.html#method-last_turn)
- [`ellmer::Chat$on_tool_request()`](https://ellmer.tidyverse.org/reference/Chat.html#method-on_tool_request)
- [`ellmer::Chat$on_tool_result()`](https://ellmer.tidyverse.org/reference/Chat.html#method-on_tool_result)
- [`ellmer::Chat$register_tool()`](https://ellmer.tidyverse.org/reference/Chat.html#method-register_tool)
- [`ellmer::Chat$register_tools()`](https://ellmer.tidyverse.org/reference/Chat.html#method-register_tools)
- [`ellmer::Chat$set_model()`](https://ellmer.tidyverse.org/reference/Chat.html#method-set_model)
- [`ellmer::Chat$set_system_prompt()`](https://ellmer.tidyverse.org/reference/Chat.html#method-set_system_prompt)
- [`ellmer::Chat$set_tools()`](https://ellmer.tidyverse.org/reference/Chat.html#method-set_tools)
- [`ellmer::Chat$set_turns()`](https://ellmer.tidyverse.org/reference/Chat.html#method-set_turns)
- [`ellmer::Chat$stream()`](https://ellmer.tidyverse.org/reference/Chat.html#method-stream)

------------------------------------------------------------------------

### `Commons$new()`

Create a Commons agent. Most users should call `commons()` rather than
this method directly.

#### Usage

    Commons$new(
      client,
      data_sources,
      context_layer = NULL,
      semantic_layer = NULL,
      system_prompt = ellmer::interpolate_file(system.file("prompts/system-prompt.md",
        package = "commons"), date = Sys.Date()),
      log = FALSE,
      share_with = NULL
    )

#### Arguments

- `client, data_sources, context_layer, semantic_layer, system_prompt, log, share_with`:

  See `commons()`.

------------------------------------------------------------------------

### `Commons$chat()`

Submit input and return the response. See
[ellmer::Chat](https://ellmer.tidyverse.org/reference/Chat.html) for
arguments.

#### Usage

    Commons$chat(..., echo = NULL)

#### Arguments

- `...`:

  Input to send to the model.

- `echo`:

  Whether to echo output; see
  [ellmer::Chat](https://ellmer.tidyverse.org/reference/Chat.html).

------------------------------------------------------------------------

### `Commons$stream_async()`

Stream input and return the response stream. See
[ellmer::Chat](https://ellmer.tidyverse.org/reference/Chat.html) for
arguments.

#### Usage

    Commons$stream_async(
      ...,
      tool_mode = c("concurrent", "sequential"),
      stream = c("text", "content"),
      controller = NULL
    )

#### Arguments

- `...`:

  Input to send to the model.

- `tool_mode`:

  Whether tool calls may run concurrently or sequentially.

- `stream`:

  Whether to stream plain text or
  [ellmer::Content](https://ellmer.tidyverse.org/reference/Content.html)
  objects.

- `controller`:

  Optional
  [`ellmer::stream_controller()`](https://ellmer.tidyverse.org/reference/stream_controller.html).

------------------------------------------------------------------------

### `Commons$citation_corpus()`

Text that can back an answer's citations: context layer documents,
measure definitions, and data dictionary entries. Used by
[`commons_server()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons_ui.md)
to verify the citations fallback answers provide; not typically called
directly.

#### Usage

    Commons$citation_corpus()

------------------------------------------------------------------------

### `Commons$prewarm()`

Build the context layer's search index ahead of the first
`search_context` call, and start a best-effort background download of
any board pins not yet loaded, warming the pins cache so their first use
is fast. Returns immediately; pins are still loaded into their data
source on demand.
[`commons_server()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons_ui.md)
does this automatically, e.g. during idle time right after a Shiny
session starts.

#### Usage

    Commons$prewarm()

------------------------------------------------------------------------

### `Commons$clone()`

The objects of this class are cloneable with this method.

#### Usage

    Commons$clone(deep = FALSE)

#### Arguments

- `deep`:

  Whether to make a deep clone.

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

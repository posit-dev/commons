#' Create a commons agent
#'
#' `commons()` creates an [ellmer::Chat] subclass with tools for a semantic
#' layer, context search, table inspection, and SQL queries.
#'
#' The provider and model come from `client`; commons sets its own system prompt
#' and tools. Use `agent$chat()` to ask questions, [commons_ui()] and
#' [commons_server()] to embed the agent in Shiny, and [vitals::generate()]
#' to use the agent as a vitals solver.
#'
#' @param client An [ellmer::Chat] giving the provider and model to use, e.g.
#'   [ellmer::chat_anthropic()]. A system prompt already set on the client is
#'   ignored, with a warning; use `system_prompt` instead.
#' @param data_sources A [data_source()], or a named list of them. Measures
#'   can take a source's connection as an argument named after the source; see
#'   [semantic_layer()]. When there are several sources, the `run_sql` and
#'   `describe_table` tools take a source's name as a `source` argument.
#' @param semantic_layer An optional [semantic_layer()].
#' @param context_layer An optional [context_layer()].
#' @param ... These dots are for future extensions and must be empty.
#' @param system_prompt The agent's system-prompt template, as a single string
#'   containing the template or the path to a template file. The default uses
#'   the markdown prompt shipped with commons. To customize the full prompt,
#'   copy that file into your project, edit it freely, and pass its path:
#'
#'   ```r
#'   file.copy(
#'     system.file("prompts/system-prompt.md", package = "commons"),
#'     "system-prompt.md"
#'   )
#'   commons(
#'     # ...
#'     system_prompt = "system-prompt.md"
#'   )
#'   ```
#'
#'   commons renders conditional sections from the agent's composition and
#'   interpolates runtime values such as its table roster. Custom templates
#'   may edit, remove, or reposition any section. To add your own substitutions,
#'   first render them with
#'   [glue::glue_file()](https://glue.tidyverse.org/reference/glue.html) using
#'   different delimiters:
#'
#'   ```r
#'   system_prompt <- glue::glue_file(
#'     "system-prompt.md",
#'     organization = "Acme",
#'     .open = "{[",
#'     .close = "]}"
#'   )
#'   commons(
#'     # ...
#'     system_prompt = as.character(system_prompt)
#'   )
#'   ```
#'
#'   A `{[organization]}` expression is resolved by glue, while commons'
#'   `{{date}}` and other template expressions remain untouched. Expressions
#'   inside `{{ }}` are evaluated as trusted R code when the agent is created.
#' @param network Whether the `run_r` session has network access. One of
#'   `"none"` (the default) or `"full"`. The session requires Linux or macOS
#'   and refuses to run without filesystem sandboxing.
#' @param log Whether to capture conversation trajectories with OpenTelemetry
#'   (default `FALSE`). When `TRUE`, commons enables GenAI message-content
#'   capture in \pkg{ellmer} and tags each turn's spans with a conversation
#'   id; the spans go wherever OTel is configured to export. On Posit Connect,
#'   traces land in Connect's observability store (browsable in its Trace
#'   Viewer); commons switches on the content's *Content Observability*
#'   setting itself when needed, though capture only starts once the content
#'   restarts. Locally, commons configures \pkg{otelsdk}'s file exporter
#'   automatically when no exporter is set up. Read trajectories back with
#'   [read_trajectories()].
#' @param share_with An optional character vector of Connect usernames granted
#'   access to this content's trajectories when running on Posit Connect.
#'   Reading traces requires editor-level access, so named users are added as
#'   collaborators on the content. Note that users whose Connect *account*
#'   role is viewer cannot read traces even when named here; trace readers
#'   need at least a publisher account.
#'
#' @return An [ellmer::Chat] subclass.
#'
#' @examples
#' \dontrun{
#' # A measure over local data computes directly in R.
#' sem <- semantic_layer(
#'   measure(
#'     "order_count",
#'     "Count of orders.",
#'     function() nrow(my_sales),
#'     arguments = list()
#'   )
#' )
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = data_source(sales = my_sales),
#'   semantic_layer = sem
#' )
#' agent$chat("How many orders are there?")
#'
#' # A measure takes a connection as an argument named after a data source.
#' # `warehouse` isn't in `arguments`, so the model never sees it; commons
#' # supplies it when the measure runs. Interpolate model-supplied arguments
#' # with glue::glue_sql() so they're quoted safely.
#' con <- DBI::dbConnect(duckdb::duckdb())
#' sem <- semantic_layer(
#'   measure(
#'     "revenue_by_region",
#'     "Total revenue for a region.",
#'     function(region, warehouse) {
#'       DBI::dbGetQuery(
#'         warehouse,
#'         glue::glue_sql(
#'           "SELECT sum(revenue) AS revenue FROM sales WHERE region = {region}",
#'           .con = warehouse
#'         )
#'       )
#'     },
#'     arguments = list(region = ellmer::type_string("Sales region."))
#'   )
#' )
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = list(warehouse = data_source(con)),
#'   semantic_layer = sem
#' )
#'
#' # Objects that aren't data sources (a pins board, an API client) come from
#' # argument defaults in the measure, e.g. `board = pins::board_connect()`.
#' # See ?semantic_layer.
#' }
#'
#' @export
commons <- function(
  client = ellmer::chat_anthropic(),
  data_sources,
  semantic_layer = NULL,
  context_layer = NULL,
  ...,
  system_prompt = system.file("prompts/system-prompt.md", package = "commons"),
  network = c("none", "full"),
  log = FALSE,
  share_with = NULL
) {
  rlang::check_dots_empty()
  if (!inherits(client, "Chat")) {
    cli::cli_abort(
      "{.arg client} must be an {.cls ellmer::Chat}, e.g. from {.fn ellmer::chat_anthropic}."
    )
  }
  if (!is.null(client$get_system_prompt())) {
    cli::cli_warn(
      c(
        "The system prompt set on {.arg client} is ignored; commons builds
         its own.",
        i = "Pass it to the {.arg system_prompt} argument instead."
      )
    )
  }
  data_sources <- as_data_sources(data_sources)
  check_context_layer(context_layer)
  semantic_layer <- semantic_layer %||% new_semantic_layer()
  check_semantic_layer(semantic_layer)
  network <- rlang::arg_match(network)
  check_run_r_sandbox()
  check_system_prompt(system_prompt)
  rlang::check_bool(log)
  check_share_with(share_with)

  Commons$new(
    client = client,
    data_sources = data_sources,
    context_layer = context_layer,
    semantic_layer = semantic_layer,
    network = network,
    system_prompt = system_prompt,
    log = log,
    share_with = share_with
  )
}

Commons <- R6::R6Class(
  "Commons",
  inherit = ellmer:::Chat,
  public = list(
    initialize = function(
      client,
      data_sources,
      semantic_layer = NULL,
      context_layer = NULL,
      ...,
      system_prompt = system.file(
        "prompts/system-prompt.md",
        package = "commons"
      ),
      network = c("none", "full"),
      log = FALSE,
      share_with = NULL
    ) {
      rlang::check_dots_empty()
      super$initialize(provider = client$get_provider(), echo = "none")
      semantic_layer <- semantic_layer %||% new_semantic_layer()
      network <- rlang::arg_match(network)

      sources <- as_data_sources(data_sources)

      private$sources <- sources
      private$context_layer <- augment_context_layer(context_layer, sources)
      private$first_touch <- new.env(parent = emptyenv())
      private$definitions <- definitions_registry(sources)
      private$registry <- semantic_layer$measures
      private$fn_sources <- semantic_layer$fn_sources
      private$injections <- resolve_injections(
        private$registry,
        measure_injectables(sources)
      )
      private$conversation_id <- new_conversation_id()
      private$tracing <- new_trajectory_tracing(log, share_with)

      # Created after new_trajectory_tracing() so a fresh `log = TRUE` local
      # exporter is already configured; otherwise otel::get_tracer() below
      # would resolve and cache a no-op provider before tracing turns on.
      local_commons_span(
        "commons_agent_create",
        attributes = list(
          "commons.agent.n_data_sources" = length(sources),
          "commons.agent.has_context_layer" = !is.null(context_layer),
          "commons.agent.n_measures" = length(semantic_layer$measures),
          "commons.agent.n_definitions" = nrow(private$definitions$defs)
        )
      )

      private$handles <- new_handle_store()
      private$worker <- new_r_worker(network)
      private$corpus <- build_citation_corpus(
        private$context_layer,
        private$registry,
        sources
      )
      private$citation_request <- new.env(parent = emptyenv())
      private$citation_request$request <- citation_request_text(
        private$registry,
        private$definitions
      )

      self$register_tools(build_commons_tools(self, private))
      self$set_system_prompt(
        commons_system_prompt(
          private$sources,
          system_prompt,
          private$definitions,
          measures = private$registry
        )
      )
    },

    chat = function(..., echo = NULL) {
      if (private$tracing) {
        local_conversation_turn_span(private$conversation_id)
      }
      super$chat(..., echo = echo)
    },

    stream_async = function(
      ...,
      tool_mode = c("concurrent", "sequential"),
      stream = c("text", "content"),
      controller = NULL
    ) {
      stream <- super$stream_async(
        ...,
        tool_mode = tool_mode,
        stream = stream,
        controller = controller
      )
      if (!private$tracing) {
        return(stream)
      }
      conversation_id <- private$conversation_id
      # The generator frame persists across yields and exits on completion,
      # so the conversation span covers the whole streamed turn.
      coro::async_generator(function() {
        local_conversation_turn_span(conversation_id)
        for (chunk in coro::await_each(stream)) {
          yield(chunk)
        }
        coro::exhausted()
      })()
    },

    citation_corpus = function() {
      private$corpus
    },

    prewarm = function() {
      layer <- private$context_layer
      if (!is.null(layer) && length(layer$docs) > 0) {
        local_commons_span(
          "commons_context_prewarm",
          attributes = list(
            "commons.context.n_docs" = length(layer$docs),
            "commons.context.cache_hit" = !is.null(layer$cache$store)
          )
        )
        context_store(layer)
      }
      for (source in private$sources) {
        source_prewarm(source)
      }
      invisible(self)
    }
  ),
  private = list(
    sources = NULL,
    context_layer = NULL,
    registry = NULL,
    definitions = NULL,
    fn_sources = NULL,
    injections = NULL,
    conversation_id = NULL,
    tracing = FALSE,
    first_touch = NULL,
    handles = NULL,
    worker = NULL,
    corpus = NULL,
    citation_request = NULL
  )
)

# Measures can take a named source's connection as an argument.
measure_injectables <- function(sources) {
  named <- sources[rlang::have_name(sources)]
  lapply(named, function(source) source$con)
}

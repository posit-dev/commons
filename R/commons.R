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
#' @param context_layer An optional [context_layer()].
#' @param semantic_layer An optional [semantic_layer()].
#' @param system_prompt The agent's system prompt, as a single string. The
#'   default interpolates the markdown prompt shipped with commons, filling
#'   its `{{date}}` keyword. To customize the prompt, copy that file into
#'   your project, edit freely, and interpolate it yourself:
#'
#'   ```r
#'   file.copy(
#'     system.file("prompts/system-prompt.md", package = "commons"),
#'     "system-prompt.md"
#'   )
#'   commons(
#'     # ...
#'     system_prompt = ellmer::interpolate_file(
#'       "system-prompt.md",
#'       date = Sys.Date()
#'     )
#'   )
#'   ```
#'
#'   Pass values for any `{{keyword}}` tokens you add as arguments to
#'   [ellmer::interpolate_file()]. commons appends documentation of the
#'   available tables and data dictionaries to the prompt itself; the file
#'   needn't (and shouldn't) describe them.
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
#' @return A `Commons` object, which subclasses [ellmer::Chat].
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
  context_layer = NULL,
  semantic_layer = NULL,
  system_prompt = ellmer::interpolate_file(
    system.file("prompts/system-prompt.md", package = "commons"),
    date = Sys.Date()
  ),
  log = FALSE,
  share_with = NULL
) {
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
  check_system_prompt(system_prompt)
  check_log(log)
  check_share_with(share_with)

  Commons$new(
    client = client,
    data_sources = data_sources,
    context_layer = context_layer,
    semantic_layer = semantic_layer,
    system_prompt = system_prompt,
    log = log,
    share_with = share_with
  )
}

#' @rdname commons
#' @export
Commons <- R6::R6Class(
  "Commons",
  inherit = ellmer:::Chat,
  public = list(
    #' @description Create a Commons agent. Most users should call [commons()]
    #'   rather than this method directly.
    #' @param client,data_sources,context_layer,semantic_layer,system_prompt,log,share_with
    #'   See [commons()].
    initialize = function(
      client,
      data_sources,
      context_layer = NULL,
      semantic_layer = NULL,
      system_prompt = ellmer::interpolate_file(
        system.file("prompts/system-prompt.md", package = "commons"),
        date = Sys.Date()
      ),
      log = FALSE,
      share_with = NULL
    ) {
      super$initialize(provider = client$get_provider(), echo = "none")
      semantic_layer <- semantic_layer %||% new_semantic_layer()

      sources <- as_data_sources(data_sources)

      private$sources <- sources
      private$context_layer <- augment_context_layer(context_layer, sources)
      private$first_touch <- new.env(parent = emptyenv())
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
          "commons.agent.n_measures" = length(semantic_layer$measures)
        )
      )

      private$handles <- new_handle_store()
      private$worker <- new_r_worker()
      private$corpus <- build_citation_corpus(
        private$context_layer,
        private$registry,
        sources
      )
      private$citation_request <- new.env(parent = emptyenv())

      self$register_tools(build_commons_tools(self, private))
      self$set_system_prompt(
        commons_system_prompt(private$sources, system_prompt)
      )
    },

    #' @description Submit input and return the response. See [ellmer::Chat]
    #'   for arguments.
    #' @param ... Input to send to the model.
    #' @param echo Whether to echo output; see [ellmer::Chat].
    chat = function(..., echo = NULL) {
      if (private$tracing) {
        local_conversation_turn_span(private$conversation_id)
      }
      super$chat(..., echo = echo)
    },

    #' @description Stream input and return the response stream. See
    #'   [ellmer::Chat] for arguments.
    #' @param ... Input to send to the model.
    #' @param tool_mode Whether tool calls may run concurrently or sequentially.
    #' @param stream Whether to stream plain text or [ellmer::Content] objects.
    #' @param controller Optional [ellmer::stream_controller()].
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

    #' @description Text that can back an answer's citations: context layer
    #'   documents, measure definitions, and data dictionary entries. Used by
    #'   [commons_server()] to verify the citations fallback answers
    #'   provide; not typically called directly.
    citation_corpus = function() {
      private$corpus
    },

    #' @description Build the context layer's search index ahead of the first
    #'   `search_context` call, and read any board tables not yet loaded into
    #'   their data source, e.g. during idle time right after a Shiny session
    #'   starts. [commons_server()] does this automatically.
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
      # One failing pin shouldn't stop the others from loading; it stays
      # pending and is retried on demand.
      for (source in private$sources) {
        tryCatch(source_ensure_all(source), error = function(err) NULL)
      }
      invisible(self)
    }
  ),
  private = list(
    sources = NULL,
    context_layer = NULL,
    registry = NULL,
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

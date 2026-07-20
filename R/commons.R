#' Create a commons agent
#'
#' `commons()` creates an [ellmer::Chat] subclass with tools for a semantic
#' layer, context search, table inspection, and SQL queries.
#'
#' The provider and model come from `client`; commons sets its own system prompt
#' and tools. Use `agent$chat()` to ask questions, [commons_mod_ui()] and
#' [commons_mod_server()] to embed the agent in Shiny, and [vitals::generate()]
#' to use the agent as a vitals solver.
#'
#' @param client An [ellmer::Chat] giving the provider and model to use, e.g.
#'   [ellmer::chat_anthropic()].
#' @param data_sources A [data_source()], or a named list of them. Measures
#'   can take a source's connection as an argument named after the source; see
#'   [semantic_layer()]. When there are several sources, the `run_sql` and
#'   `describe_table` tools take a source's name as a `source` argument.
#' @param context_layer An optional [context_layer()].
#' @param semantic_layer An optional [semantic_layer()].
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
  log = FALSE,
  share_with = NULL
) {
  if (!inherits(client, "Chat")) {
    cli::cli_abort(
      "{.arg client} must be an {.cls ellmer::Chat}, e.g. from {.fn ellmer::chat_anthropic}."
    )
  }
  data_sources <- as_data_sources(data_sources)
  check_context_layer(context_layer)
  semantic_layer <- semantic_layer %||% new_semantic_layer()
  check_semantic_layer(semantic_layer)
  check_log(log)
  check_share_with(share_with)

  Commons$new(
    client = client,
    data_sources = data_sources,
    context_layer = context_layer,
    semantic_layer = semantic_layer,
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
    #' @param client,data_sources,context_layer,semantic_layer,log,share_with
    #'   See [commons()].
    initialize = function(
      client,
      data_sources,
      context_layer = NULL,
      semantic_layer = NULL,
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
      private$injections <- resolve_injections(
        private$registry,
        measure_injectables(sources)
      )
      private$conversation_id <- new_conversation_id()
      private$tracing <- new_trajectory_tracing(log, share_with)
      private$handles <- new_handle_store()

      self$register_tools(build_commons_tools(self, private))
      self$set_system_prompt(
        commons_system_prompt(private$sources, private$context_layer)
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

    #' @description Build the context layer's search index ahead of the first
    #'   `search_context` call, e.g. during idle time right after a Shiny
    #'   session starts. [commons_mod_server()] does this automatically.
    prewarm = function() {
      layer <- private$context_layer
      if (!is.null(layer) && length(layer$docs) > 0) {
        context_store(layer)
      }
      invisible(self)
    }
  ),
  private = list(
    sources = NULL,
    context_layer = NULL,
    registry = NULL,
    injections = NULL,
    conversation_id = NULL,
    tracing = FALSE,
    first_touch = NULL,
    handles = NULL
  )
)

# Measures can take a named source's connection as an argument.
measure_injectables <- function(sources) {
  named <- sources[rlang::have_name(sources)]
  lapply(named, function(source) source$con)
}

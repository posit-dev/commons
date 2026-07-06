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
#' @param data_sources A [data_source()], or a named list of one or more of
#'   them along with any other objects measures need, such as a pins board or
#'   an API client. Measures can take an entry as an argument named after it;
#'   see [semantic_layer()]. When there are several sources, the `run_sql` and
#'   `describe_table` tools take a source's name as a `source` argument.
#' @param context_layer An optional [context_layer()].
#' @param semantic_layer An optional [semantic_layer()].
#' @param log Whether to log conversation trajectories. `FALSE` disables
#'   logging. `TRUE` uses private Connect pins on Posit Connect and local files
#'   elsewhere. A single string is treated as a local directory path to write
#'   trajectory files.
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
#' # Other named entries (pins boards, API clients) work the same way.
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = list(
#'     warehouse = data_source(con),
#'     board = pins::board_connect()
#'   ),
#'   semantic_layer = semantic_layer("R/semantic_layer.R")
#' )
#' }
#'
#' @export
commons <- function(
  client = ellmer::chat_anthropic(),
  data_sources,
  context_layer = NULL,
  semantic_layer = NULL,
  log = FALSE
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

  Commons$new(
    client = client,
    data_sources = data_sources,
    context_layer = context_layer,
    semantic_layer = semantic_layer,
    log = log
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
    #' @param client An [ellmer::Chat] supplying the provider.
    #' @param data_sources A [data_source()], or a named list of one or more
    #'   of them along with any other objects measures need.
    #' @param context_layer An optional [context_layer()].
    #' @param semantic_layer An optional [semantic_layer()].
    #' @param log Whether to log conversation trajectories.
    initialize = function(
      client,
      data_sources,
      context_layer = NULL,
      semantic_layer = NULL,
      log = FALSE
    ) {
      super$initialize(provider = client$get_provider(), echo = "none")
      semantic_layer <- semantic_layer %||% new_semantic_layer()

      sources <- as_data_sources(data_sources)
      is_source <- vapply(sources, inherits, logical(1), "commons_data_source")

      private$sources <- sources[is_source]
      private$context_layer <- context_layer
      private$registry <- semantic_layer$measures
      private$injections <- resolve_injections(
        private$registry,
        measure_injectables(sources)
      )
      private$logger <- new_trajectory_logger(log)

      self$register_tools(build_commons_tools(self, private))
      self$set_system_prompt(
        commons_system_prompt(private$sources, private$context_layer)
      )
    },

    #' @description Submit input and return the response. Also writes a turn
    #'   log. See [ellmer::Chat] for arguments.
    #' @param ... Input to send to the model.
    #' @param echo Whether to echo output; see [ellmer::Chat].
    chat = function(..., echo = NULL) {
      response <- super$chat(..., echo = echo)
      private$finalize_turn()
      response
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
      coro::async_generator(function() {
        for (chunk in coro::await_each(stream)) {
          yield(chunk)
        }
        private$finalize_turn()
        coro::exhausted()
      })()
    }
  ),
  private = list(
    sources = NULL,
    context_layer = NULL,
    registry = NULL,
    injections = NULL,
    logger = NULL,

    finalize_turn = function() {
      record_trajectory(
        private$logger,
        self
      )
      invisible(NULL)
    }
  )
)

# Everything a measure can take by name: a data_source() contributes its
# connection, any other entry contributes itself.
measure_injectables <- function(sources) {
  named <- sources[rlang::have_name(sources)]
  lapply(named, function(entry) {
    if (inherits(entry, "commons_data_source")) entry$con else entry
  })
}

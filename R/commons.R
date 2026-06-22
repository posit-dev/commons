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
#' @param data_source A [data_source()].
#' @param context_layer An optional [context_layer()].
#' @param semantic_layer An optional [semantic_layer()].
#' @param log_dir Directory for per-turn JSON logs. If `NULL`, defaults to
#'   `Sys.getenv("COMMONS_LOG_DIR")`, or a session temp directory if unset.
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
#' src <- data_source(sales = my_sales)
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_source = src,
#'   semantic_layer = sem
#' )
#' agent$chat("How many orders are there?")
#' agent$last_tag # "A"
#'
#' # A measure over a database closes over the connection. For canned SQL,
#' # interpolate arguments with glue::glue_sql() so they're quoted safely.
#' con <- DBI::dbConnect(duckdb::duckdb())
#' sem <- semantic_layer(
#'   measure(
#'     "revenue_by_region",
#'     "Total revenue for a region.",
#'     function(region) {
#'       DBI::dbGetQuery(
#'         con,
#'         glue::glue_sql(
#'           "SELECT sum(revenue) AS revenue FROM sales WHERE region = {region}",
#'           .con = con
#'         )
#'       )
#'     },
#'     arguments = list(region = ellmer::type_string("Sales region."))
#'   )
#' )
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_source = data_source(con),
#'   semantic_layer = sem
#' )
#'
#' # To reuse an existing function that takes a connection, wrap it so its
#' # formals are just the measure's arguments.
#' sem <- semantic_layer(
#'   measure(
#'     "revenue_metrics",
#'     "Revenue metrics over a date range.",
#'     function(start_date, end_date) {
#'       pull_revenue_metrics(con, start_date, end_date)
#'     },
#'     arguments = list(
#'       start_date = ellmer::type_string("Start date, YYYY-MM-DD."),
#'       end_date = ellmer::type_string("End date, YYYY-MM-DD.")
#'     )
#'   )
#' )
#' }
#'
#' @export
commons <- function(
  client = ellmer::chat_anthropic(),
  data_source,
  context_layer = NULL,
  semantic_layer = NULL,
  log_dir = NULL
) {
  if (!inherits(client, "Chat")) {
    cli::cli_abort(
      "{.arg client} must be an {.cls ellmer::Chat}, e.g. from {.fn ellmer::chat_anthropic}."
    )
  }
  check_data_source(data_source)
  check_context_layer(context_layer)
  semantic_layer <- semantic_layer %||% new_semantic_layer()
  check_semantic_layer(semantic_layer)
  log_dir <- log_dir %||% commons_log_dir()

  Commons$new(
    client = client,
    data_source = data_source,
    context_layer = context_layer,
    semantic_layer = semantic_layer,
    log_dir = log_dir
  )
}

commons_log_dir <- function() {
  Sys.getenv("COMMONS_LOG_DIR", unset = file.path(tempdir(), "commons-logs"))
}

#' @rdname commons
#' @export
Commons <- R6::R6Class(
  "Commons",
  inherit = ellmer:::Chat,
  public = list(
    #' @field last_tag How the most recent answer was produced: `"A"` for a
    #'   registered measure, `"B"` for SQL, or `NA`.
    last_tag = NA_character_,

    #' @description Create a Commons agent. Most users should call [commons()]
    #'   rather than this method directly.
    #' @param client An [ellmer::Chat] supplying the provider.
    #' @param data_source A [data_source()].
    #' @param context_layer An optional [context_layer()].
    #' @param semantic_layer An optional [semantic_layer()].
    #' @param log_dir Directory for turn logs.
    initialize = function(
      client,
      data_source,
      context_layer = NULL,
      semantic_layer = NULL,
      log_dir = NULL
    ) {
      super$initialize(provider = client$get_provider(), echo = "none")
      semantic_layer <- semantic_layer %||% new_semantic_layer()
      log_dir <- log_dir %||% commons_log_dir()

      private$data_source <- data_source
      private$context_layer <- context_layer
      private$registry <- semantic_layer$measures
      private$log_dir <- log_dir

      self$register_tools(build_commons_tools(self, private))
      self$on_tool_request(function(request) {
        private$turn_calls <- c(private$turn_calls, request@name)
        self$last_tag <- derive_tag(private$turn_calls)
        invisible()
      })
      self$set_system_prompt(
        commons_system_prompt(private$data_source, private$context_layer)
      )
    },

    #' @description Submit input and return the response. Also updates
    #'   `$last_tag` and writes a turn log. See [ellmer::Chat] for arguments.
    #' @param ... Input to send to the model.
    #' @param echo Whether to echo output; see [ellmer::Chat].
    chat = function(..., echo = NULL) {
      private$turn_calls <- character()
      response <- super$chat(..., echo = echo)
      private$finalize_turn(response)
      response
    },

    #' @description Stream input and return the response stream. Also updates
    #'   `$last_tag` as tools are requested. See [ellmer::Chat] for arguments.
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
      private$turn_calls <- character()
      self$last_tag <- NA_character_
      super$stream_async(
        ...,
        tool_mode = tool_mode,
        stream = stream,
        controller = controller
      )
    }
  ),
  private = list(
    data_source = NULL,
    context_layer = NULL,
    registry = NULL,
    log_dir = NULL,
    turn_calls = character(),

    finalize_turn = function(response) {
      self$last_tag <- derive_tag(private$turn_calls)
      question <- self$last_turn(role = "user")
      write_trajectory(
        private$log_dir,
        list(
          time = format(Sys.time()),
          question = if (!is.null(question)) question@text else NA_character_,
          answer = as.character(response),
          tag = self$last_tag,
          tools = as.list(private$turn_calls)
        )
      )
    }
  )
)

#' Create a commons agent
#'
#' `commons()` creates an [ellmer::Chat] subclass with tools for registered
#' measures, context search, table inspection, and SQL queries.
#'
#' The provider and model come from `client`; commons sets its own system prompt
#' and tools. Use `agent$chat()` to ask questions, [commons_mod_ui()] and
#' [commons_mod_server()] to embed the agent in Shiny, and [vitals::generate()]
#' to use the agent as a vitals solver.
#'
#' @param client An [ellmer::Chat] giving the provider and model to use, e.g.
#'   [ellmer::chat_anthropic()].
#' @param source A [data_source()].
#' @param context An optional [context_store()].
#' @param log_dir Directory for per-turn JSON logs. Defaults to a session temp
#'   directory.
#'
#' @return A `Commons` object, which subclasses [ellmer::Chat].
#'
#' @examples
#' \dontrun{
#' src <- data_source(sales = my_sales)
#' agent <- commons(ellmer::chat_anthropic(), source = src)
#'
#' # A measure over local data computes directly in R.
#' agent$register_measure(
#'   "order_count",
#'   "Count of orders.",
#'   function() nrow(my_sales),
#'   arguments = list()
#' )
#' agent$chat("How many orders are there?")
#' agent$last_tag # "A"
#'
#' # A measure over a database closes over the connection. For canned SQL,
#' # interpolate arguments with glue::glue_sql() so they're quoted safely.
#' con <- DBI::dbConnect(duckdb::duckdb())
#' agent <- commons(ellmer::chat_anthropic(), source = data_source(con))
#' agent$register_measure(
#'   "revenue_by_region",
#'   "Total revenue for a region.",
#'   function(region) {
#'     DBI::dbGetQuery(
#'       con,
#'       glue::glue_sql(
#'         "SELECT sum(revenue) AS revenue FROM sales WHERE region = {region}",
#'         .con = con
#'       )
#'     )
#'   },
#'   arguments = list(region = ellmer::type_string("Sales region."))
#' )
#'
#' # To reuse an existing function that takes a connection, wrap it so its
#' # formals are just the measure's arguments.
#' agent$register_measure(
#'   "revenue_metrics",
#'   "Revenue metrics over a date range.",
#'   function(start_date, end_date) {
#'     pull_revenue_metrics(con, start_date, end_date)
#'   },
#'   arguments = list(
#'     start_date = ellmer::type_string("Start date, YYYY-MM-DD."),
#'     end_date = ellmer::type_string("End date, YYYY-MM-DD.")
#'   )
#' )
#' }
#'
#' @export
commons <- function(
  client = ellmer::chat_anthropic(),
  source,
  context = NULL,
  log_dir = file.path(tempdir(), "commons-logs")
) {
  if (!inherits(client, "Chat")) {
    cli::cli_abort(
      "{.arg client} must be an {.cls ellmer::Chat}, e.g. from {.fn ellmer::chat_anthropic}."
    )
  }
  check_data_source(source)
  check_context_store(context)

  Commons$new(
    client = client,
    source = source,
    context = context,
    log_dir = log_dir
  )
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
    #' @param source A [data_source()].
    #' @param context An optional [context_store()].
    #' @param log_dir Directory for turn logs.
    initialize = function(client, source, context = NULL, log_dir = tempdir()) {
      super$initialize(provider = client$get_provider(), echo = "none")

      private$source <- source
      private$context <- context
      private$registry <- list()
      private$log_dir <- log_dir

      self$register_tools(build_commons_tools(self, private))
      self$on_tool_request(function(request) {
        private$turn_calls <- c(private$turn_calls, request@name)
        self$last_tag <- derive_tag(private$turn_calls)
        invisible()
      })
      self$set_system_prompt(commons_system_prompt(private$source, private$context))
    },

    #' @description Register a measure. Measures are stored as [ellmer::tool()]
    #'   objects and called by name through the `call_measure` tool. Returns the
    #'   agent invisibly.
    #'
    #'   A measure is any function whose formals are the arguments you want the
    #'   model to supply. Where the data lives determines how you write it:
    #'
    #'   * Local data: compute directly in R over the in-memory object.
    #'   * A database: query a connection. For canned SQL, close over the
    #'     connection and call [DBI::dbGetQuery()] (use [glue::glue_sql()] to
    #'     interpolate arguments safely). To reuse an existing connection-taking
    #'     function (e.g. from another package), wrap it in a closure that fixes
    #'     the connection.
    #'
    #'   Functions that return a lazy `dbplyr` table are collected before
    #'   formatting.
    #' @param name Measure name.
    #' @param description What the measure computes.
    #' @param fn Function that computes the measure. Its formals are the
    #'   measure's arguments.
    #' @param arguments A named list of [ellmer::type_string()] and friends, one
    #'   per formal of `fn`.
    register_measure = function(name, description, fn, arguments = list()) {
      private$registry[[name]] <- ellmer::tool(
        fn,
        description,
        arguments = arguments,
        name = name
      )
      invisible(self)
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
    source = NULL,
    context = NULL,
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

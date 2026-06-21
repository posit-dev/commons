#' Create a commons agent
#'
#' `commons()` creates an [ellmer::Chat] subclass with tools for registered
#' measures, context search, table inspection, and SQL queries.
#'
#' The provider and model come from `client`; commons sets its own system prompt
#' and tools. Use `agent$chat()` to ask questions, [shinychat::chat_app()] to
#' open a chat UI, and [vitals::generate()] to use the agent as a vitals solver.
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
#' agent$register_measure(
#'   "order_count",
#'   "Count of orders.",
#'   function() nrow(my_sales),
#'   arguments = list()
#' )
#' agent$chat("How many orders are there?")
#' agent$last_tag # "A"
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
        invisible()
      })
      private$refresh_prompt()
    },

    #' @description Register a measure. Measures are stored as [ellmer::tool()]
    #'   objects and called by name through the `call_measure` tool. Returns the
    #'   agent invisibly.
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
      private$refresh_prompt()
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
    }
  ),
  private = list(
    source = NULL,
    context = NULL,
    registry = NULL,
    log_dir = NULL,
    turn_calls = character(),

    refresh_prompt = function() {
      self$set_system_prompt(commons_system_prompt(
        private$source,
        private$context,
        private$registry
      ))
    },

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

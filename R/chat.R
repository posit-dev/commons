#' Shiny chat UI and server for commons agents
#'
#' These functions wrap [shinychat::chat_ui()] and [shinychat::chat_server()]
#' for commons agents. The server verifies each `<commons-citation>` the
#' model writes against its own context, measure definitions, and data
#' documentation as the answer streams, and rewrites verified citations
#' inline as server-authored `<shiny-aside>` elements naming their source.
#' A compact provenance aside follows the answer when it was produced by a
#' governed calculation, or when a fallback answer cites nothing verified.
#'
#' @param id The ID of the chat element; must match between `commons_ui()`
#'   and `commons_server()`.
#' @param ... In `commons_ui()`, extra arguments passed to
#'  [shinychat::chat_ui()]. In `commons_server()`, arguments passed to
#'  [shinychat::chat_server()].
#' @param client A [commons()] agent. Create a new agent for each Shiny session.
#'
#' @return `commons_ui()` returns UI. `commons_server()` returns the
#'   [shinychat::chat_server()] result.
#'
#' @examples
#' \dontrun{
#' library(shiny)
#'
#' ui <- page_fillable(
#'   commons_ui("chat")
#' )
#'
#' server <- function(input, output, session) {
#'   agent <- commons(
#'     ellmer::chat_anthropic(),
#'     data_sources = data_source(sales = sales)
#'   )
#'   commons_server("chat", agent)
#' }
#'
#' shinyApp(ui, server)
#' }
#'
#' @export
commons_ui <- function(id, ...) {
  check_chat_packages()
  register_commons_icon_resources()
  ui <- shinychat::chat_ui(id, icon_assistant = htmltools::HTML(""), ...)
  htmltools::attachDependencies(ui, commons_chat_dependency(), append = TRUE)
}

#' @rdname commons_ui
#' @export
commons_server <- function(id, client, ...) {
  check_chat_packages()
  check_commons_client(client)
  local_commons_span(
    "commons_server_start",
    attributes = list("commons.server.id" = id)
  )

  # Build the context index and start the background pin-cache download
  # during post-startup idle time (while the user reads the welcome message).
  # Errors are swallowed: the first search retries the index build and
  # surfaces the failure to the model, and an unwarmed pin is simply
  # downloaded at its first use.
  later::later(function() {
    tryCatch(client$prewarm(), error = function(err) NULL)
  })

  chat <- shinychat::chat_server(id, client = client, ...)
  persist_conversation_id(chat, client)
  chat
}

# shinychat reuses one client across saved conversations, so persist each
# conversation's trace identity with its history.
persist_conversation_id <- function(chat, client) {
  chat$history$on_save(function(values) {
    values$commons_conversation_id <- client$get_conversation_id()
    values
  })
  chat$history$on_restore(function(values) {
    id <- values$commons_conversation_id
    if (rlang::is_string(id) && nzchar(id)) {
      client$set_conversation_id(id)
    }
  })
  invisible(chat)
}

check_chat_packages <- function(call = rlang::caller_env()) {
  missing <- c("htmltools", "shiny", "shinychat")[
    !vapply(
      c("htmltools", "shiny", "shinychat"),
      requireNamespace,
      logical(1),
      quietly = TRUE
    )
  ]

  if (length(missing)) {
    cli::cli_abort(
      c(
        "The {.pkg commons} chat module requires missing package{?s}: {.pkg {missing}}.",
        i = "Install {.pkg {missing}} to use {.fn commons_ui} and {.fn commons_server}."
      ),
      call = call
    )
  }
}

check_commons_client <- function(client, call = rlang::caller_env()) {
  if (!inherits(client, "Commons")) {
    cli::cli_abort(
      "{.arg client} must be an agent created by {.fn commons}.",
      call = call
    )
  }
}

register_commons_icon_resources <- function() {
  shiny::addResourcePath(
    COMMONS_ICON_RESOURCE_PREFIX,
    system.file("figs", package = "commons")
  )
}

# Asset mtimes ride in the version so the dependency URL changes whenever
# the files do; browsers otherwise cache edited assets under the stable
# version's URL indefinitely.
commons_chat_dependency <- function() {
  src <- system.file("www", "commons-chat", package = "commons")
  stamp <- max(file.mtime(list.files(src, full.names = TRUE)))

  htmltools::htmlDependency(
    name = "commons-chat",
    version = paste0("0.0.0.9000.", as.integer(stamp)),
    src = c(file = src),
    stylesheet = "commons-chat.css",
    script = "commons-chat.js"
  )
}

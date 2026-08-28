#' Shiny chat app for a commons agent
#'
#' `commons_app()` composes [commons_server()] and [commons_theme()] into a
#' complete app for local development. To customize and deploy the Shiny app, 
#' assemble the UI and server yourself with [commons_theme()] and 
#' [commons_server()].
#'
#' @param client A [commons()] agent.
#' @param ... Extra arguments passed to [shiny::shinyApp()].
#'
#' @return A [shiny::shinyApp()] object.
#'
#' @section Citations and provenance:
#' The server verifies citations against trusted calculations, context, and data
#' documentation as the answer streams. Verified citations appear inline, with
#' details that name the trusted source. A provenance marker follows the answer
#' when it was produced by a trusted calculation, or when a fallback answer
#' cites nothing verified.
#'
#' @examples
#' \dontrun{
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = data_source(sales = sales)
#' )
#' commons_app(agent)
#' }
#'
#' @export
commons_app <- function(client, ...) {
  check_chat_packages()
  check_commons_client(client)

  ui <- function(req) {
    shinychat::page_chat(
      "commons",
      id = "chat",
      theme = commons_theme(),
      toolbar_global = if (rlang::is_interactive()) {
        bslib::toolbar(
          bslib::input_dark_mode(),
          shiny::actionButton("close_btn", label = "", class = "btn-close")
        )
      }
    )
  }

  server <- function(input, output, session) {
    if (rlang::is_interactive()) {
      shiny::setBookmarkExclude("close_btn")
      shiny::observeEvent(input$close_btn, label = "on_close_btn", {
        shiny::stopApp()
      })
    }
    commons_server("chat", client)
  }

  shiny::shinyApp(ui, server, ..., enableBookmarking = "url")
}

#' Chat server and theme for custom commons apps
#'
#' These are the building blocks for deploying a commons chat as a Shiny
#' app; for local development, use [commons_app()]. Pair `commons_server()`
#' with [shinychat::page_chat()] or [shinychat::chat_ui()], passing
#' `theme = commons_theme()` so the commons chat assets are on the page.
#'
#' `commons_theme()` bundles the commons chat CSS and JavaScript into an
#' ordinary [bslib::bs_theme()] (via [shinychat::page_chat_theme()]), so it
#' works anywhere a bslib theme does.
#'
#' @param client A [commons()] agent. In a deployed app, create the agent
#'   inside the server function and pass it to `commons_server()` so each
#'   Shiny session gets its own agent state.
#' @param id The ID of the chat element; must match the `id` of the
#'   [shinychat::page_chat()] or [shinychat::chat_ui()] on the page.
#' @param ... In `commons_server()`, arguments passed to
#'   [shinychat::chat_server()]. In `commons_theme()`, named Sass variables
#'   forwarded to [shinychat::page_chat_theme()].
#' @param preset A bslib or Bootswatch preset name.
#'
#' @return `commons_server()` returns the [shinychat::chat_server()] result.
#'   `commons_theme()` returns a [bslib::bs_theme()] object.
#'
#' @examples
#' \dontrun{
#' library(shiny)
#' library(shinychat)
#'
#' ui <- page_chat("Assistant", id = "chat", theme = commons_theme())
#'
#' server <- function(input, output, session) {
#'   # One agent per session, so each user gets their own agent state
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
#' @name commons_server
#' @export
commons_server <- function(id, client, ...) {
  check_chat_packages()
  check_commons_client(client)
  local_commons_span(
    "commons_server_start",
    attributes = list("commons.server.id" = id)
  )

  commons_prewarm(client)

  chat <- shinychat::chat_server(id, client = client, ...)
  # shinychat owns the conversation identity (it sets the client's
  # `conversation_id` binding, which ellmer stamps on its spans); commons
  # only needs to know that a restore happened.
  chat$history$on_restore(function(values) {
    client$queue_restore_reminder()
  })
  chat
}

#' Pre-warm a commons agent during post-startup idle time
#'
#' A [commons()] agent defers two kinds of setup to first use, and exposes a
#' `prewarm()` method for each so you can move the cost off the first
#' question:
#'
#' * `agent$prewarm_context()` builds the context index (the store behind
#'   `search_context`). It is synchronous and in-process: the index is
#'   in-memory, so each Shiny session's agent builds its own.
#' * `agent$prewarm_sources()` starts a background process that downloads
#'   any uncached pins into the local pins cache (see [data_source()]).
#'   Because the pins cache is on disk, this can also run ahead of
#'   deployment — outside the Shiny runtime entirely — and the deployed
#'   app reads the warmed cache.
#'
#' `agent$prewarm()` calls both. Call `commons_prewarm()` in a Shiny server
#' function to defer warming to post-startup idle time, so it happens while
#' the user reads the welcome message.
#'
#' `prewarm()` lets failures propagate, since a direct call is typically
#' warming caches ahead of deployment and a mere warning would sail through
#' a deploy script. `commons_prewarm()` downgrades such failures to
#' warnings: pre-warming is a pure optimization — everything it builds is
#' rebuilt lazily at first use — and an error escaping the [later::later()]
#' callback would stop the app.
#'
#' @param client A [commons()] agent.
#'
#' @return `NULL`, invisibly.
#'
#' @examples
#' \dontrun{
#' server <- function(input, output, session) {
#'   agent <- commons(
#'     ellmer::chat_anthropic(),
#'     data_sources = data_source(sales = sales)
#'   )
#'   commons_prewarm(agent)
#'   shinychat::chat_server("chat", client = agent)
#' }
#' }
#'
#' @export
commons_prewarm <- function(client) {
  check_commons_client(client)
  # An error escaping a later::later() callback stops the Shiny app, and
  # pre-warming is a pure optimization, so downgrade failures to warnings.
  later::later(function() {
    tryCatch(
      client$prewarm(),
      error = function(err) cli::cli_warn(conditionMessage(err))
    )
  })
  invisible(NULL)
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
        i = "Install {.pkg {missing}} to use the {.pkg commons} chat functions."
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

# Asset mtimes ride in the version so the dependency URL changes whenever
# the files do; browsers otherwise cache edited assets under the stable
# version's URL indefinitely.
commons_chat_dependency <- function() {
  src <- system.file("www", "commons-chat", package = "commons")
  stamp <- max(file.mtime(list.files(src, full.names = TRUE, recursive = TRUE)))

  htmltools::htmlDependency(
    name = "commons-chat",
    version = paste0("0.0.0.9000.", as.integer(stamp)),
    src = c(file = src),
    script = "commons-chat.js",
    stylesheet = "commons-chat.css",
    all_files = TRUE
  )
}

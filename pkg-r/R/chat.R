#' Shiny chat app for a commons agent
#'
#' `commons_app()` composes [shinychat::page_chat()], [commons_theme()], and
#' [shinychat::chat_server()] into a complete app for local development. To
#' customize and deploy the Shiny app, assemble the UI and server yourself
#' with [commons_theme()] and [shinychat::chat_server()].
#'
#' @param client A [commons()] agent.
#' @param ... Extra arguments passed to [shiny::shinyApp()].
#'
#' @return A [shiny::shinyApp()] object.
#'
#' @section Citations and provenance:
#' The server verifies citations against trusted calculations, context, and
#' data documentation as the answer streams. Verified citations appear inline,
#' with details that name the trusted source. A provenance marker follows the
#' answer when it was produced by a trusted calculation, or when a fallback
#' answer cites nothing verified.
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
    commons_prewarm(client)
    shinychat::chat_server("chat", client = client)
  }

  shiny::shinyApp(ui, server, ..., enableBookmarking = "url")
}

#' Theme for custom commons chat apps
#'
#' `commons_theme()` is the building block for deploying a commons chat as a
#' Shiny app; for local development, use [commons_app()]. Pair
#' [shinychat::page_chat()] or [shinychat::chat_ui()] with
#' [shinychat::chat_server()], passing `theme = commons_theme()` so the
#' commons chat assets are on the page.
#'
#' `commons_theme()` bundles the commons chat CSS and JavaScript into an
#' ordinary [bslib::bs_theme()] (via [shinychat::page_chat_theme()]), so it
#' works anywhere a bslib theme does.
#'
#' @param ... Named Sass variables forwarded to
#'   [shinychat::page_chat_theme()].
#' @param preset A bslib or Bootswatch preset name.
#'
#' @return A [bslib::bs_theme()] object.
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
#'   # Build the context index during post-startup idle time
#'   commons_prewarm(agent)
#'   chat_server("chat", client = agent)
#' }
#'
#' shinyApp(ui, server)
#' }
#'
#' @name commons_theme
#' @export
commons_theme <- function(..., preset = "shiny") {
  theme <- shinychat::page_chat_theme(
    "border-radius" = "1rem",
    "border-radius-sm" = "1rem",
    "shiny-chat-page-title-font-weight" = 300,
    "shiny-chat-user-message-border-radius" = "0.75rem",
    "shiny-chat-user-message-padding" = "0.5rem 1.5rem",
    ...,
    preset = preset
  )
  bslib::bs_bundle(
    theme,
    sass::sass_layer(html_deps = list(commons_chat_dependency()))
  )
}

#' Pre-warm a commons agent during post-startup idle time
#'
#' A [commons()] agent builds its context index on first use. To move that
#' cost off the first question, call `commons_prewarm()` in a Shiny server
#' function: it defers the agent's `prewarm()` method to post-startup idle
#' time, so the index builds while the user reads the welcome message.
#'
#' `prewarm()` is synchronous and independent of the Shiny runtime, so it can
#' also be called directly to warm the on-disk cache ahead of deployment. It
#' also starts a background process that downloads any uncached pins into the
#' local pins cache (see [data_source()]).
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
    stylesheet = "commons-chat.css",
    all_files = TRUE
  )
}

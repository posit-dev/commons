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
      drawer = shinychat::chat_drawer(width = 640, open = FALSE),
      toolbar_global = bslib::toolbar(
        commons_share_button("chat"),
        if (rlang::is_interactive()) {
          htmltools::tagList(
            bslib::input_dark_mode(),
            shiny::actionButton("close_btn", label = "", class = "btn-close")
          )
        }
      )
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
#' Documents the agent writes open in the chat's drawer, which
#' [shinychat::page_chat()] and [shinychat::chat_ui()] enable by default. An app
#' that passes `drawer = FALSE` gets no documents in view, though the agent
#' still writes them. Documents read best in a wider drawer than the default,
#' e.g. `drawer = shinychat::chat_drawer(width = 640, open = FALSE)`.
#'
#' On Posit Connect, viewers can share a read-only copy of a conversation or
#' document; see [commons_share_button()].
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

  prewarm_on_idle(client)

  chat <- shinychat::chat_server(id, client = client, ...)
  share_input <- share_server(
    id,
    client,
    chat,
    session = shiny::getDefaultReactiveDomain()
  )
  artifact_drawer_server(id, client, share_input = share_input)
  # shinychat owns the conversation identity (it sets the client's
  # `conversation_id` binding, which ellmer stamps on its spans); commons
  # only needs to know that a restore happened.
  store <- client$artifact_store()
  chat$history$on_save(function(values) {
    values$commons_documents <- artifact_store_snapshot(store)
    values$commons_shares <- store$shares
    values
  })
  chat$history$on_restore(function(values) {
    client$queue_restore_reminder()
    artifact_store_restore(store, values$commons_documents)
    store$shares <- values$commons_shares %||% list()
  })
  chat
}

# An error escaping a later::later() callback would stop the app, so
# downgrade failures to warnings.
prewarm_on_idle <- function(client) {
  later::later(function() {
    tryCatch(
      client$prewarm(),
      error = function(err) {
        msg <- conditionMessage(err)
        cli::cli_warn("{msg}")
      }
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
    script = c("commons-chat.js", "commons-artifact.js"),
    stylesheet = c("commons-chat.css", "commons-artifact.css"),
    all_files = TRUE
  )
}

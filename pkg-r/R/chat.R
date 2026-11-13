#' Shiny chat app for a commons agent
#'
#' `commons_app()` composes [commons_server()] and [commons_theme()] into a
#' complete app for local development. To customize and deploy the Shiny app, 
#' assemble the UI and server yourself with [commons_theme()] and 
#' [commons_server()].
#'
#' @param client An [agent()].
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
#' agent <- agent(
#'   ellmer::chat_anthropic(),
#'   commons = commons(data_sources = data_source(sales = sales))
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
#' Documents the agent writes open in the chat's drawer, which
#' [shinychat::page_chat()] and [shinychat::chat_ui()] enable by default. An app
#' that passes `drawer = FALSE` gets no documents in view, though the agent
#' still writes them. Documents read best in a wider drawer than the default,
#' e.g. `drawer = shinychat::chat_drawer(width = 640, open = FALSE)`.
#'
#' `commons_theme()` bundles the commons chat CSS and JavaScript into an
#' ordinary [bslib::bs_theme()] (via [shinychat::page_chat_theme()]), so it
#' works anywhere a bslib theme does.
#'
#' @section Sharing on Posit Connect:
#' On Posit Connect, viewers can publish a read-only copy of a conversation,
#' document, plot, or table. `commons_server()` adds a share button to a
#' [shinychat::page_chat()] toolbar for the conversation, the same control to
#' documents in the chat's drawer, and one beside plots and tables. An app
#' built with [shinychat::chat_ui()] has no toolbar, so its conversations
#' can't be shared, but its documents, plots, and tables can.
#'
#' Sharing is available only when the app runs on Posit Connect and its
#' deployer has associated a Connect integration of the "Connect API" type
#' with the "Visitor API Key" authentication type and a max role of Publisher
#' or Admin. Through it, a copy is published as the viewer who shares it, so
#' only viewers whose Connect account can publish content can share.
#'
#' Sharing opens a dialog with a link to the copy, which is published as the
#' dialog opens. The copy is static content that belongs to the viewer who
#' shared it. In the dialog, they add people and groups who can open it, or
#' open it to anyone who can access the app: for an app shared with a list of
#' people, that list is copied once, so people added to the app later aren't
#' added to the copy. A first share canceled before its link is copied or
#' anyone is added is deleted.
#'
#' The dialog offers only people who can access the app, but the copy belongs
#' to the viewer, who can open it to anyone from the Connect dashboard. Treat
#' that limit as a convenience, not a data boundary.
#'
#' A copy shows what was displayed, including the results of the agent's
#' calculations, so anyone it is shared with sees those results without
#' needing access to the data behind them. A shared plot or table includes the
#' code that made it. Nothing in a copy can reach the model or continue the
#' conversation. Sharing the same thing again opens the existing copy at the
#' same link and, if what it shows has changed, offers to update it.
#'
#' @param client An [agent()]. In a deployed app, create the agent
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
#'   agent <- agent(
#'     ellmer::chat_anthropic(),
#'     commons = commons(data_sources = data_source(sales = sales))
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
  chat$history$on_restore(function(values) {
    client$queue_restore_reminder()
    store <- client$artifact_store()
    if (!is.null(store)) {
      artifact_store_restore(store, values$commons_artifacts)
    }
  })
  if (!is.null(client$artifact_store())) {
    chat$history$on_save(function(values) {
      values$commons_artifacts <- artifact_store_values(client$artifact_store())
      values
    })
  }
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

#' Share a conversation to Posit Connect
#'
#' `commons_share_button()` places a button that publishes a read-only copy of
#' the conversation to Posit Connect. Put it in the page's toolbar, e.g.
#' `page_chat(toolbar_global = bslib::toolbar(commons_share_button()))`;
#' [commons_app()] includes it. Documents the agent writes get the same
#' control in the chat's drawer.
#'
#' The button appears only when the app runs on Posit Connect and its
#' deployer has associated a Connect integration of the "Connect API" type
#' with the "Visitor API Key" authentication type and a max role of Publisher
#' or Admin. Through it, a copy is published as the viewer who shares it, so
#' only viewers whose Connect account can publish content can share.
#'
#' A shared copy is static content that belongs to the viewer who shared it.
#' Only they can see it at first; they choose who else can in Connect. It shows
#' the conversation as it was displayed, including the results of the
#' agent's calculations, so anyone it is shared with sees those results
#' without needing access to the data behind them. Nothing in a copy can reach
#' the model or continue the conversation. Sharing the same conversation or
#' document again updates the existing copy.
#'
#' @param id The ID of the chat element, matching [commons_server()].
#'
#' @return A [shiny::uiOutput()].
#' @export
commons_share_button <- function(id = "chat") {
  shiny::uiOutput(paste0(id, "_share"), inline = TRUE)
}

# Returns the input the drawer's share control sets, or NULL when this
# session can't share.
share_server <- function(id, client, chat, session) {
  if (!is_connect_runtime()) {
    return(NULL)
  }
  token <- session$request$HTTP_POSIT_CONNECT_USER_SESSION_TOKEN
  if (is.null(token)) {
    return(NULL)
  }
  audience <- connect_share_audience()
  if (is.null(audience)) {
    return(NULL)
  }

  store <- client$artifact_store()
  open_input <- paste0(id, "_share_open")
  document_input <- paste0(id, "_artifact_share")
  confirm_input <- paste0(id, "_share_confirm")
  target <- NULL

  session$output[[paste0(id, "_share")]] <- shiny::renderUI(
    bslib::toolbar_input_button(
      session$ns(open_input),
      label = "Share",
      icon = maybe_icon("box-arrow-up")
    )
  )

  task <- shiny::ExtendedTask$new(function(target, archive) {
    connect_share(
      token,
      audience,
      archive,
      target$title,
      guid = target$receipt$guid,
      on_created = function(content) {
        store$shares[[target$key]] <- share_receipt(content)
      }
    )
  })

  offer <- function(new_target) {
    if (task$status() == "running") {
      return(share_modal("Sharing", "A copy is still being published."))
    }
    target <<- new_target
    shiny::showModal(share_confirm_modal(target, session$ns(confirm_input)))
  }

  shiny::observeEvent(session$input[[open_input]], {
    if (identical(chat$status(), "streaming")) {
      share_modal("Share this conversation", "Wait for the answer to finish.")
    } else if (length(client$get_turns()) == 0) {
      share_modal("Share this conversation", "There's nothing to share yet.")
    } else {
      offer(share_conversation_target(client))
    }
  })

  shiny::observeEvent(session$input[[document_input]], {
    artifact <- artifact_get(store, session$input[[document_input]]$artifact)
    if (!is.null(artifact) && identical(artifact$status, "ready")) {
      offer(share_document_target(store, artifact))
    }
  })

  shiny::observeEvent(session$input[[confirm_input]], {
    dir <- tempfile("commons-share-")
    dir.create(dir)
    if (identical(target$kind, "conversation")) {
      write_conversation_bundle(client, dir)
    } else {
      write_document_bundle(artifact_get(store, target$id), dir)
    }
    task$invoke(target, bundle_archive(dir))
    share_modal(target$heading, "Publishing to Posit Connect\u2026")
  })

  shiny::observeEvent(task$status(), {
    status <- task$status()
    if (status == "success") {
      receipt <- share_receipt(task$result())
      store$shares[[target$key]] <- receipt
      # The receipt is saved with the conversation, which otherwise saves only
      # when an answer finishes.
      tryCatch(chat$history$save(), error = function(err) NULL)
      shiny::showModal(share_done_modal(target, receipt))
    } else if (status == "error") {
      err <- tryCatch(task$result(), error = identity)
      if (!inherits(err, "commons_share_error")) {
        cli::cli_warn("Sharing to Posit Connect failed.", parent = err)
      }
      share_modal(target$heading, share_error_message(err))
    }
  }, ignoreInit = TRUE)

  session$ns(document_input)
}

share_conversation_target <- function(client) {
  store <- client$artifact_store()
  list(
    kind = "conversation",
    key = "conversation",
    heading = "Share this conversation",
    title = share_title(conversation_title(client$get_turns())),
    receipt = store$shares[["conversation"]]
  )
}

share_document_target <- function(store, artifact) {
  key <- paste0("document:", artifact$id)
  list(
    kind = "document",
    id = artifact$id,
    key = key,
    heading = "Share this document",
    title = share_title(artifact$title),
    receipt = store$shares[[key]]
  )
}

# Connect requires a title of 3 to 1024 characters without line breaks.
share_title <- function(title) {
  title <- trimws(gsub("[\t\n\f\r]+", " ", title))
  if (nchar(title) < 3) "Shared from commons" else substr(title, 1, 1024)
}

share_receipt <- function(content) {
  list(
    guid = content$guid,
    url = content$content_url,
    dashboard_url = content$dashboard_url
  )
}

share_confirm_modal <- function(target, confirm_id) {
  update <- !is.null(target$receipt$url)
  shiny::modalDialog(
    title = target$heading,
    htmltools::p(
      "Publish a read-only copy to Posit Connect. It belongs to you, and only",
      "you can see it until you give others access in Connect."
    ),
    htmltools::p(
      "It includes the results you saw here. Anyone you share it with sees",
      "them, even without access to the data behind them."
    ),
    if (update) {
      htmltools::p(
        "This updates ",
        htmltools::a(
          "the copy you shared before",
          href = target$receipt$url,
          target = "_blank",
          .noWS = "after"
        ),
        "."
      )
    },
    footer = htmltools::tagList(
      shiny::modalButton("Cancel"),
      shiny::actionButton(
        confirm_id,
        if (update) "Update" else "Share",
        class = "btn-primary"
      )
    ),
    easyClose = TRUE
  )
}

share_done_modal <- function(target, receipt) {
  shiny::modalDialog(
    title = target$heading,
    htmltools::p(
      "Your copy is on Posit Connect: ",
      htmltools::a(receipt$url, href = receipt$url, target = "_blank")
    ),
    htmltools::p(
      "Only you can see it until you ",
      htmltools::a(
        "give others access",
        href = paste0(receipt$dashboard_url, "/access"),
        target = "_blank",
        .noWS = "after"
      ),
      "."
    ),
    footer = shiny::modalButton("Done"),
    easyClose = TRUE
  )
}

share_modal <- function(title, text) {
  shiny::showModal(shiny::modalDialog(
    title = title,
    htmltools::p(text),
    footer = shiny::modalButton("Close"),
    easyClose = TRUE
  ))
}

share_abort <- function(reason, parent = NULL, call = rlang::caller_env()) {
  cli::cli_abort(
    share_error_messages[[reason]],
    class = "commons_share_error",
    parent = parent,
    call = call
  )
}

share_error_messages <- list(
  role = paste(
    "Your Connect account can't publish content. Ask your Connect",
    "administrator for a Publisher account."
  ),
  session = "Your Connect session has expired. Reload the page and try again.",
  deploy = "Posit Connect couldn't deploy the copy. Try again.",
  timeout = "Posit Connect took too long to deploy the copy. Try again."
)

share_error_message <- function(err) {
  if (inherits(err, "commons_share_error")) {
    return(conditionMessage(err))
  }
  "Couldn't share to Posit Connect. Try again."
}

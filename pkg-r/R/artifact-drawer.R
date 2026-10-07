# Shows artifacts in shinychat's drawer. The drawer is filled once with a
# <commons-artifact-view>, because every drawer update replaces its content
# wholesale (reloading any iframe); streaming and renders reach the view as
# custom messages instead.
artifact_drawer_server <- function(
  id,
  client,
  session = shiny::getDefaultReactiveDomain()
) {
  store <- client$artifact_store()
  view <- session$ns(id)
  open_input <- paste0(id, "_artifact_open")
  store$link_input <- session$ns(open_input)

  drawer <- new.env(parent = emptyenv())
  drawer$mounted <- FALSE

  send <- function(event) {
    session$sendCustomMessage(
      "commons-artifact",
      c(list(view = view), drop_nulls(event))
    )
  }
  show <- function(title) {
    if (drawer$mounted) {
      shinychat::chat_drawer_show(id, title = title, session = session)
    } else {
      shinychat::chat_drawer_show(
        id,
        content = artifact_view_ui(view),
        title = title,
        session = session
      )
      drawer$mounted <- TRUE
    }
  }

  store$listener <- function(event) {
    switch(
      event$type,
      open = ,
      version = show(event$title),
      reset = {
        if (drawer$mounted) {
          shinychat::chat_drawer_hide(id, session = session)
        }
      }
    )
    send(event)
  }

  shiny::observeEvent(session$input[[open_input]], {
    artifact <- artifact_get(store, session$input[[open_input]]$artifact)
    if (is.null(artifact)) {
      return()
    }
    show(artifact$title)
    send(artifact_select_event(artifact))
  })
  invisible(NULL)
}

artifact_view_ui <- function(view) {
  htmltools::tag(
    "commons-artifact-view",
    list(
      view = view,
      htmltools::div(class = "commons-artifact-status"),
      htmltools::div(class = "commons-artifact-notice"),
      htmltools::div(class = "commons-artifact-body")
    )
  )
}

# Empty strings rather than NULLs, which would arrive as truthy empty objects.
artifact_select_event <- function(artifact) {
  version <- length(artifact$versions)
  failed <- identical(artifact$failed_version, version)
  list(
    type = "select",
    id = artifact$id,
    title = artifact$title,
    version = version,
    source = artifact$versions[[version]]$source,
    html = artifact$html %||% "",
    html_version = artifact$html_version,
    status = if (failed) {
      "failed"
    } else if (artifact$html_version == version) {
      "ready"
    } else {
      "rendering"
    },
    error = if (failed) artifact$error else ""
  )
}

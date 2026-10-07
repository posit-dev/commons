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
  download_output <- paste0(id, "_artifact_download")
  store$link_input <- session$ns(open_input)

  drawer <- new.env(parent = emptyenv())
  drawer$mounted <- FALSE
  drawer$current <- NULL

  send <- function(event) {
    session$sendCustomMessage(
      "commons-artifact",
      c(list(view = view), drop_nulls(event))
    )
  }
  show <- function(artifact_id, title) {
    drawer$current <- artifact_id
    if (drawer$mounted) {
      shinychat::chat_drawer_show(id, title = title, session = session)
    } else {
      shinychat::chat_drawer_show(
        id,
        content = artifact_view_ui(view, session$ns(download_output)),
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
      version = show(event$id, event$title),
      reset = {
        drawer$current <- NULL
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
    show(artifact$id, artifact$title)
    send(artifact_select_event(artifact))
  })

  session$output[[download_output]] <- shiny::downloadHandler(
    filename = function() paste0(drawer$current, ".zip"),
    content = function(file) artifact_zip(store, drawer$current, file)
  )
  invisible(NULL)
}

artifact_view_ui <- function(view, download_id) {
  htmltools::tag(
    "commons-artifact-view",
    list(
      view = view,
      htmltools::div(
        class = "commons-artifact-toolbar",
        htmltools::div(class = "commons-artifact-status"),
        shiny::downloadLink(
          download_id,
          "Download",
          class = "commons-artifact-download"
        )
      ),
      htmltools::div(class = "commons-artifact-notice"),
      htmltools::div(class = "commons-artifact-body")
    )
  )
}

# Everything the view needs to show an artifact again from scratch. Empty
# strings rather than NULLs, which would arrive as truthy empty objects.
artifact_select_event <- function(artifact) {
  version <- length(artifact$versions)
  failed <- identical(artifact$failed_version, version)
  list(
    type = "select",
    id = artifact$id,
    title = artifact$title,
    version = version,
    trusted = artifact$versions[[version]]$trusted,
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

# Static bundles a viewer shares to Posit Connect. Connect serves them as
# they are, so a shared conversation has no R process behind it: nothing in it
# can reach a model or take input.

write_conversation_bundle <- function(client, dir, shared_on = Sys.Date()) {
  store <- client$artifact_store()
  ids <- Filter(function(id) !is.null(artifact_get(store, id)), ls(store$artifacts))
  documents <- list()
  for (id in ids) {
    path <- file.path("documents", paste0(id, ".html"))
    write_document_page(artifact_get(store, id), file.path(dir, path))
    documents[[id]] <- path
  }

  messages <- shared_messages(client)
  page <- shinychat::page_chat(
    conversation_title(client$get_turns()),
    id = "chat",
    theme = commons_theme(),
    sidebar = FALSE,
    drawer = FALSE,
    footer = sprintf(
      "A read-only copy of a conversation, shared on %s.",
      format(shared_on, "%Y-%m-%d")
    )
  )
  # Asset URLs carry the version of the deployment that streamed them, which
  # a restored conversation may outlive.
  dep <- commons_chat_dependency()
  wire <- gsub(
    "commons-chat-[0-9.]+/",
    paste0(dep$name, "-", dep$version, "/"),
    wire_messages_json(messages)
  )
  page <- htmltools::tagQuery(page)$
    find("shiny-chat-container")$
    addAttrs(`data-initial-messages` = wire)$
    allTags()
  page <- htmltools::tagList(
    page,
    htmltools::tags$style(".shiny-chat-composer { display: none; }"),
    htmltools::tags$script(
      type = "application/json",
      id = "commons-shared-documents",
      htmltools::HTML(jsonlite::toJSON(documents, auto_unbox = TRUE))
    )
  )
  page <- htmltools::attachDependencies(
    page,
    message_dependencies(messages),
    append = TRUE
  )
  # Dependencies sit at the root, where Shiny serves them, so URLs built for
  # the live app (like aside icons) resolve.
  htmltools::save_html(page, file.path(dir, "index.html"), libdir = ".")
  write_static_manifest(dir)
}

write_document_bundle <- function(artifact, dir) {
  write_document_page(artifact, file.path(dir, "index.html"))
  write_static_manifest(dir)
}

write_document_page <- function(artifact, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(
    artifact_document_html(artifact$title, artifact$html),
    path,
    sep = "",
    useBytes = TRUE
  )
}

# A restored conversation's tool requests lost their definitions in storage,
# and with them the icons the live chat showed.
shared_messages <- function(client) {
  tools <- client$get_tools()
  turns <- lapply(client$get_turns(), function(turn) {
    turn@contents <- lapply(turn@contents, function(content) {
      if (
        S7::S7_inherits(content, ellmer::ContentToolRequest) &&
          is.null(content@tool) &&
          content@name %in% names(tools)
      ) {
        content@tool <- tools[[content@name]]
      }
      content
    })
    turn
  })
  chat <- new_trajectory_chat()
  chat$set_turns(turns)
  chat$set_tools(tools)
  shinychat::contents_shinychat(chat)
}

# Temporary: shinychat has no public way to serialize messages for its chat
# element, so this borrows the one its history uses. Remove once
# posit-dev/shinychat#379 lands.
wire_messages_json <- function(messages) {
  serialize <- utils::getFromNamespace(
    "build_stored_message_from_content",
    "shinychat"
  )
  wire <- lapply(messages, function(message) {
    serialize(message$role, message$content)
  })
  as.character(jsonlite::toJSON(wire, auto_unbox = TRUE, null = "null", force = TRUE))
}

message_dependencies <- function(messages) {
  contents <- lapply(messages, `[[`, "content")
  htmltools::findDependencies(contents)
}

conversation_title <- function(turns) {
  for (turn in turns) {
    if (!S7::S7_inherits(turn, ellmer::UserTurn)) {
      next
    }
    texts <- Filter(
      function(x) identical(S7::S7_class(x), ellmer::ContentText),
      turn@contents
    )
    text <- trimws(gsub("\\s+", " ", paste(
      vapply(texts, function(x) x@text, character(1)),
      collapse = " "
    )))
    if (nzchar(text)) {
      return(truncate_title(text))
    }
  }
  "Conversation"
}

truncate_title <- function(text, max_chars = 80) {
  if (nchar(text) <= max_chars) {
    return(text)
  }
  paste0(substr(text, 1, max_chars - 1), "…")
}

write_static_manifest <- function(dir) {
  files <- list.files(dir, recursive = TRUE, all.files = TRUE)
  files <- setdiff(files, "manifest.json")
  checksums <- lapply(files, function(file) {
    list(checksum = unname(tools::md5sum(file.path(dir, file))))
  })
  manifest <- list(
    version = 1L,
    metadata = list(appmode = "static", primary_html = "index.html"),
    files = rlang::set_names(checksums, files)
  )
  jsonlite::write_json(
    manifest,
    file.path(dir, "manifest.json"),
    auto_unbox = TRUE,
    pretty = TRUE
  )
  invisible(dir)
}

bundle_archive <- function(dir) {
  path <- tempfile(fileext = ".tar.gz")
  old <- setwd(dir)
  on.exit(setwd(old), add = TRUE)
  utils::tar(
    path,
    files = list.files(".", recursive = TRUE, all.files = TRUE),
    compression = "gzip",
    tar = "internal"
  )
  path
}

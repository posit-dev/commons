#' Shiny module for commons agents
#'
#' These functions wrap [shinychat::chat_mod_ui()] and
#' [shinychat::chat_mod_server()] with commons-specific answer provenance UI.
#' Answers produced from registered measures get a compact verified-answer pill.
#' Answers produced from fallback SQL get a caution pill.
#'
#' @param id Module ID.
#' @param ... Arguments passed to [shinychat::chat_mod_ui()] or
#'   [shinychat::chat_mod_server()].
#' @param messages Initial messages shown in the chat. Passed to
#'   [shinychat::chat_mod_ui()].
#' @param height Chat container height. Defaults to `"100%"` so the chat input
#'   stays docked at the bottom of fill layouts.
#' @param client A [commons()] agent. Create a new agent for each Shiny session.
#' @param bookmark_on_input,bookmark_on_response Whether to add Shiny
#'   bookmarking hooks for user inputs and assistant responses.
#'
#' @return `commons_mod_ui()` returns UI. `commons_mod_server()` returns the
#'   shinychat module server result.
#'
#' @examples
#' \dontrun{
#' library(shiny)
#'
#' ui <- page_fillable(
#'   commons_mod_ui("chat")
#' )
#'
#' server <- function(input, output, session) {
#'   agent <- commons(
#'     ellmer::chat_anthropic(),
#'     data_sources = data_source(sales = sales)
#'   )
#'   commons_mod_server("chat", agent)
#' }
#'
#' shinyApp(ui, server)
#' }
#'
#' @export
commons_mod_ui <- function(id, ..., messages = NULL, height = "100%") {
  check_chat_packages()
  ui <- shinychat::chat_mod_ui(id, ..., messages = messages, height = height)
  htmltools::attachDependencies(ui, commons_chat_dependency(), append = TRUE)
}

#' @rdname commons_mod_ui
#' @export
commons_mod_server <- function(
  id,
  client,
  bookmark_on_input = TRUE,
  bookmark_on_response = TRUE
) {
  check_chat_packages()
  check_commons_client(client)

  # Build the context index during post-startup idle time (while the user
  # reads the welcome message) rather than inside the first search. Errors are
  # swallowed: the first search retries the build and surfaces the failure to
  # the model.
  later::later(function() {
    tryCatch(client$prewarm(), error = function(err) NULL)
  })

  mod <- shinychat::chat_mod_server(
    id,
    client = client,
    bookmark_on_input = bookmark_on_input,
    bookmark_on_response = bookmark_on_response
  )

  shiny::moduleServer(id, function(input, output, session) {
    session$onFlushed(function() {
      seed_commons_pills(session, client)
    }, once = TRUE)

    shiny::observeEvent(mod$last_turn(), {
      tag <- commons_last_tag(client)
      if (is.na(tag)) {
        return()
      }

      send_commons_pill(session, tag)
    }, ignoreNULL = TRUE)
  })

  mod
}

send_commons_pill <- function(session, tag) {
  html <- htmltools::renderTags(commons_answer_pill(tag))$html
  session$sendCustomMessage(
    "commonsProvenancePill",
    list(id = session$ns("chat"), html = html)
  )
}

# Restored history renders as streams, so all seeded pills go in one
# message and the client places them only once the transcript settles.
seed_commons_pills <- function(session, client) {
  tags <- commons_exchange_tags(
    client$get_turns(include_system_prompt = FALSE)
  )
  n <- length(tags)
  pills <- list()
  for (i in seq_len(n)) {
    if (is.na(tags[[i]])) {
      next
    }
    pills[[length(pills) + 1]] <- list(
      html = htmltools::renderTags(commons_answer_pill(tags[[i]]))$html,
      indexFromEnd = n - i
    )
  }
  if (length(pills) == 0) {
    return(invisible())
  }

  session$sendCustomMessage(
    "commonsProvenancePillSeed",
    list(id = session$ns("chat"), count = n, pills = pills)
  )
}

check_chat_packages <- function(call = rlang::caller_env()) {
  missing <- c("htmltools", "shiny", "shinychat")[
    !vapply(c("htmltools", "shiny", "shinychat"), requireNamespace, logical(1), quietly = TRUE)
  ]

  if (length(missing)) {
    cli::cli_abort(
      c(
        "The {.pkg commons} chat module requires missing package{?s}: {.pkg {missing}}.",
        i = "Install {.pkg {missing}} to use {.fn commons_mod_ui} and {.fn commons_mod_server}."
      ),
      call = call
    )
  }
}

check_commons_client <- function(client, call = rlang::caller_env()) {
  if (!inherits(client, "Commons")) {
    cli::cli_abort(
      "{.arg client} must be a {.cls Commons} object created by {.fn commons}.",
      call = call
    )
  }
}

commons_answer_pill <- function(tag) {
  switch(
    tag,
    A = htmltools::tags$span(
      class = "commons-answer-pill commons-answer-pill-trusted",
      title = "This answer comes from a governed calculation defined by your data team.",
      `aria-label` = "Verified answer. This answer comes from a governed calculation defined by your data team.",
      `data-commons-tooltip` = "This answer comes from a governed calculation defined by your data team.",
      tabindex = "0",
      commons_pill_icon("trusted-icon.svg", "Verified answer"),
      htmltools::tags$span("Verified answer")
    ),
    B = htmltools::tags$span(
      class = "commons-answer-pill commons-answer-pill-caution",
      title = "This answer was generated from available context and data, but was not produced by a governed calculation.",
      `aria-label` = "AI can be wrong. This answer was generated from available context and data, but was not produced by a governed calculation.",
      `data-commons-tooltip` = "This answer was generated from available context and data, but was not produced by a governed calculation.",
      commons_pill_icon("warning-icon.svg", "AI can be wrong"),
      htmltools::tags$span("AI can be wrong.")
    ),
    NULL
  )
}

commons_pill_icon <- function(file, alt) {
  path <- system.file("figs", file, package = "commons")
  if (!nzchar(path)) {
    return(NULL)
  }

  svg <- paste(readLines(path, warn = FALSE), collapse = "\n")
  svg <- sub("^\\s*<\\?xml[^>]*\\?>\\s*", "", svg)
  src <- paste0(
    "data:image/svg+xml,",
    utils::URLencode(svg, reserved = TRUE)
  )

  htmltools::tags$img(
    src = src,
    alt = alt,
    class = "commons-answer-pill-icon"
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

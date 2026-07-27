#' Shiny chat UI and server for commons agents
#'
#' These functions wrap [shinychat::chat_ui()] and [shinychat::chat_server()]
#' with commons-specific answer provenance UI. Answers produced from
#' registered measures get a compact verified-answer pill. Answers produced
#' from fallback SQL or R can cite text from the agent's context, measure
#' definitions, or data documentation; verified citations render as footnotes
#' whose tooltips name their source. Fallback answers with no verified
#' citation get an untrusted caution pill.
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
  ui <- shinychat::chat_ui(id, ...)
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

  session <- shiny::getDefaultReactiveDomain()

  shiny::observeEvent(chat$last_turn(), ignoreNULL = TRUE, {
    provenance <- commons_last_provenance(client)
    if (is.na(provenance$tag)) {
      return()
    }

    send_commons_pill(session, id, provenance)
  })

  session$onFlushed(
    function() {
      seed_commons_pills(session, id, client)
    },
    once = TRUE
  )

  chat
}

send_commons_pill <- function(session, id, provenance) {
  html <- htmltools::renderTags(commons_answer_pill(provenance$tag))$html
  session$sendCustomMessage(
    "commonsProvenancePill",
    list(
      id = session$ns(id),
      html = html,
      citations = citations_payload(provenance$citations)
    )
  )
}

# Restored history renders as streams, so all seeded pills go in one
# message and the client places them only once the transcript settles.
seed_commons_pills <- function(session, id, client) {
  provenances <- commons_exchange_provenance(
    client$get_turns(include_system_prompt = FALSE),
    client$citation_corpus()
  )
  n <- length(provenances)
  pills <- list()
  for (i in seq_len(n)) {
    if (is.na(provenances[[i]]$tag)) {
      next
    }
    pills[[length(pills) + 1]] <- list(
      html = htmltools::renderTags(
        commons_answer_pill(provenances[[i]]$tag)
      )$html,
      citations = citations_payload(provenances[[i]]$citations),
      indexFromEnd = n - i
    )
  }
  if (length(pills) == 0) {
    return(invisible())
  }

  session$sendCustomMessage(
    "commonsProvenancePillSeed",
    list(id = session$ns(id), count = n, pills = pills)
  )
}

# The client assembles the footnote tooltip from these fields (see
# footnote() in commons-chat.js); unverified entries carry nothing but
# their position.
citations_payload <- function(citations) {
  lapply(citations, function(citation) {
    if (!citation$verified) {
      return(list(verified = FALSE))
    }
    list(
      verified = TRUE,
      reason = if (!is.na(citation$reason)) citation$reason,
      quote = normalize_citation(citation$quote),
      label = citation$label
    )
  })
}

check_chat_packages <- function(call = rlang::caller_env()) {
  missing <- c("htmltools", "shiny", "shinychat")[
    !vapply(c("htmltools", "shiny", "shinychat"), requireNamespace, logical(1), quietly = TRUE)
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
    # Cited fallback answers ("B") get no pill: their citation footnotes are
    # the provenance UI.
    C = htmltools::tags$span(
      class = "commons-answer-pill commons-answer-pill-caution",
      title = "This answer was generated from available context and data, but was not produced by a governed calculation and cites none of your organization's definitions. AI can be wrong.",
      `aria-label` = "Untrusted. This answer was generated from available context and data, but was not produced by a governed calculation and cites none of your organization's definitions. AI can be wrong.",
      `data-commons-tooltip` = "This answer was generated from available context and data, but was not produced by a governed calculation and cites none of your organization's definitions. AI can be wrong.",
      tabindex = "0",
      commons_pill_icon("warning-icon.svg", "Untrusted"),
      htmltools::tags$span("Untrusted.")
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

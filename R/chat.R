#' Shiny module for commons agents
#'
#' These functions wrap [shinychat::chat_mod_ui()] and
#' [shinychat::chat_mod_server()] with commons-specific answer provenance UI.
#' Answers produced from registered measures get a compact verified-answer
#' pill. Answers produced from fallback SQL or R can cite text from the
#' agent's context, measure definitions, or data documentation; verified
#' citations render as footnotes whose tooltips name their source. Fallback
#' answers with no verified citation get a potentially-untrusted caution pill.
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
      provenance <- commons_last_provenance(client)
      if (is.na(provenance$tag)) {
        return()
      }

      send_commons_pill(session, provenance)
    }, ignoreNULL = TRUE)
  })

  mod
}

send_commons_pill <- function(session, provenance) {
  html <- htmltools::renderTags(commons_answer_pill(provenance$tag))$html
  session$sendCustomMessage(
    "commonsProvenancePill",
    list(
      id = session$ns("chat"),
      html = html,
      citations = citations_payload(provenance$citations)
    )
  )
}

# Restored history renders as streams, so all seeded pills go in one
# message and the client places them only once the transcript settles.
seed_commons_pills <- function(session, client) {
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
    list(id = session$ns("chat"), count = n, pills = pills)
  )
}

# One entry per <citation> element the answer rendered, in order; the client
# replaces the i-th element with a footnote (verified) or removes it.
citations_payload <- function(citations) {
  lapply(citations, function(citation) {
    list(
      verified = citation$verified,
      tooltip = if (citation$verified) {
        sprintf(
          "\u201c%s\u201d \u2014 %s",
          normalize_citation(citation$quote),
          citation$label
        )
      }
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
    # Cited fallback answers ("B") get no pill: their citation footnotes are
    # the provenance UI.
    C = htmltools::tags$span(
      class = "commons-answer-pill commons-answer-pill-caution",
      title = "This answer was generated from available context and data, but was not produced by a governed calculation and cites none of your organization's definitions. AI can be wrong.",
      `aria-label` = "Potentially untrusted. This answer was generated from available context and data, but was not produced by a governed calculation and cites none of your organization's definitions. AI can be wrong.",
      `data-commons-tooltip` = "This answer was generated from available context and data, but was not produced by a governed calculation and cites none of your organization's definitions. AI can be wrong.",
      tabindex = "0",
      commons_pill_icon("warning-icon.svg", "Potentially untrusted"),
      htmltools::tags$span("Potentially untrusted.")
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

#' Shiny module for commons agents
#'
#' These functions wrap [shinychat::chat_mod_ui()] and
#' [shinychat::chat_mod_server()] with commons-specific answer provenance UI.
#' Answers produced from registered measures get a compact trusted-answer pill.
#' Answers produced from fallback SQL get a caution pill with a review request.
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
#'   commons::commons_mod_ui("chat")
#' )
#'
#' server <- function(input, output, session) {
#'   src <- data_source(sales = sales)
#'   agent <- commons(ellmer::chat_anthropic(), source = src)
#'   commons::commons_mod_server("chat", agent)
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

  mod <- shinychat::chat_mod_server(
    id,
    client = client,
    bookmark_on_input = bookmark_on_input,
    bookmark_on_response = bookmark_on_response
  )

  shiny::moduleServer(id, function(input, output, session) {
    shiny::observeEvent(mod$last_turn(), {
      tag <- client$last_tag
      if (is.na(tag)) {
        return()
      }

      review_id <- NULL
      if (identical(tag, "B")) {
        review_id <- next_review_id()
        observe_review_request(review_id, client, mod$last_input())
      }

      send_commons_pill(session, tag, review_id)
    }, ignoreNULL = TRUE)
  })

  mod
}

send_commons_pill <- function(session, tag, review_id = NULL) {
  review_input_id <- if (is.null(review_id)) NULL else session$ns(review_id)
  html <- htmltools::renderTags(
    commons_answer_pill(tag, review_input_id)
  )$html

  session$sendCustomMessage(
    "commonsProvenancePill",
    list(
      id = session$ns("chat"),
      html = html,
      inputId = review_input_id
    )
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

commons_answer_pill <- function(tag, review_id = NULL) {
  switch(
    tag,
    A = htmltools::tags$span(
      class = "commons-answer-pill commons-answer-pill-trusted",
      htmltools::tags$span(class = "commons-answer-pill-dot"),
      htmltools::tags$span("Trusted answer")
    ),
    B = htmltools::tags$span(
      class = "commons-answer-pill commons-answer-pill-caution",
      htmltools::tags$span(class = "commons-answer-pill-dot"),
      htmltools::tags$span("AI can be wrong."),
      htmltools::tags$span("If you want, you can"),
      htmltools::tags$button(
        id = review_id,
        class = "commons-review-link",
        type = "button",
        `data-commons-review-trigger` = "",
        "Request review."
      )
    ),
    NULL
  )
}

observe_review_request <- function(review_id, client, question) {
  session <- shiny::getDefaultReactiveDomain()
  shiny::observeEvent(session$input[[review_id]], {
    answer <- commons_turn_text(client$last_turn())
    shinychat::update_chat_user_input(
      "chat",
      value = review_request_prompt(question, answer),
      submit = TRUE,
      session = session
    )
  }, ignoreInit = TRUE, once = TRUE)
}

review_request_prompt <- function(question, answer = NULL) {
  paste(
    "Please perform an adversarial review of your previous answer.",
    "",
    "Focus on load-bearing assumptions and what could be wrong: data sources,",
    "metric definitions, filters, joins, date windows, grain, missing context,",
    "and unsupported interpretation. If something needs validation, say exactly",
    "what to check.",
    sep = "\n"
  )
}

commons_turn_text <- function(turn) {
  if (is.null(turn)) {
    return(NA_character_)
  }
  turn@text %||% as.character(turn)
}

next_review_id <- local({
  i <- 0L
  function() {
    i <<- i + 1L
    sprintf("commons_request_review_%s", i)
  }
})

commons_chat_dependency <- function() {
  htmltools::htmlDependency(
    name = "commons-chat",
    version = "0.0.0.9000",
    package = "commons",
    src = "www/commons-chat",
    stylesheet = "commons-chat.css",
    script = "commons-chat.js"
  )
}

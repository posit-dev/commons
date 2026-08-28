provenance_display <- list(
  A = list(
    label = "Verified answer",
    icon = "trusted-icon.svg",
    body = paste(
      "This answer comes from a trusted calculation defined by",
      "your data team."
    ),
    pill_class = "trusted"
  ),
  B = list(
    label = "Cited",
    icon = NULL,
    body = "This answer includes supporting text verified against a trusted source.",
    pill_class = "cited"
  ),
  C = list(
    label = "Untrusted",
    icon = "warning-icon.svg",
    body = paste(
      "This answer was not produced by a trusted calculation and has",
      "no verified supporting citation. AI can be wrong."
    ),
    pill_class = "caution"
  )
)

# A fallback claim remains fallback even when its answer also uses a governed
# calculation, so its citation verdict takes precedence.
derive_provenance_tag <- function(tags, verified) {
  if ("B" %in% tags) {
    if (verified) "B" else "C"
  } else if ("A" %in% tags) {
    "A"
  } else {
    NA_character_
  }
}

# Live answers omit the "Cited" marker: their verified citation asides
# already say as much. Review contexts set include_cited = TRUE so every
# classified answer carries its outcome.
provenance_aside <- function(tag, include_cited = FALSE) {
  entry <- provenance_display[[tag]]
  if (is.null(entry) || (identical(tag, "B") && !include_cited)) {
    return("")
  }
  icon <- commons_icon_url(entry$icon)
  sprintf(
    '<shiny-aside label="%s"%s>%s</shiny-aside>',
    escape_attr(entry$label),
    if (is.null(icon)) "" else sprintf(' icon="%s"', escape_attr(icon)),
    paste(entry$body, as.character(provenance_info_control()), sep = "\n\n")
  )
}

provenance_info_control <- function() {
  trigger <- shiny::actionLink(
    provenance_info_input_id,
    label = htmltools::tags$span(`aria-hidden` = "true", "i"),
    class = "commons-provenance-info-trigger",
    `aria-label` = "How answer trust is determined"
  )

  htmltools::tags$div(
    class = "commons-provenance-info",
    trigger
  )
}

provenance_info_modal <- function() {
  shiny::modalDialog(
    provenance_info_body(),
    title = "How answer trust is determined",
    footer = shiny::modalButton("Close"),
    easyClose = TRUE
  )
}

provenance_info_server <- function(input, session) {
  registered <- "commons_provenance_info_registered"
  if (isTRUE(session$userData[[registered]])) {
    return(invisible(NULL))
  }
  session$userData[[registered]] <- TRUE

  shiny::observeEvent(
    input[[provenance_info_input_id]],
    shiny::showModal(provenance_info_modal(), session = session),
    domain = session,
    ignoreInit = TRUE
  )
}

provenance_info_input_id <- "commons_provenance_info"

provenance_info_body <- function() {
  htmltools::tags$div(
    class = "commons-provenance-info-body",
    htmltools::tags$p(
      paste(
        "This application asks an AI agent to use trusted calculations",
        "whenever possible. When no relevant calculation is available, the",
        "agent may write code itself."
      )
    ),
    htmltools::tags$ul(
      class = "commons-provenance-info-list",
      provenance_info_item(
        "A",
        label = "Trusted",
        "trusted-icon.svg",
        body = paste(
          "For the given answer, the agent only searched for",
          "and invoked a human-vetted calculation."
        )
      ),
      provenance_info_item(
        label = "No marker",
        body = paste(
          "For answers that don't do any new calculations, the application shows no badge."
        )
      ),
      provenance_info_item(
        "B",
        "citation-mark.svg",
        paste(
          "The agent did ad-hoc analysis and was able to",
          "cite vetted context that supported its approach."
        )
      ),
      provenance_info_item(
        "C",
        "warning-icon.svg",
        htmltools::tagList(
          "The agent did ad-hoc analysis and was ",
          htmltools::tags$strong("not"),
          " able to cite vetted context that supported its approach."
        )
      )
    ),
    htmltools::tags$p(
      paste(
        "The agent itself does not choose the badge.",
        "The badge is chosen by the application based on",
        "the agent's response."
      )
    )
  )
}

provenance_info_item <- function(
  tag = NULL,
  icon = NULL,
  body = NULL,
  label = NULL
) {
  if (!is.null(tag)) {
    entry <- provenance_display[[tag]]
    label <- label %||% entry$label
    body <- body %||% entry$body
  }

  marker <- if (is.null(icon)) {
    htmltools::tags$span(
      class = "commons-provenance-info-no-marker",
      `aria-hidden` = "true",
      "\u2014"
    )
  } else {
    htmltools::tags$img(
      src = commons_icon_url(icon),
      alt = "",
      `aria-hidden` = "true"
    )
  }

  htmltools::tags$li(
    htmltools::tags$div(
      class = "commons-provenance-info-label",
      marker,
      htmltools::tags$strong(label)
    ),
    htmltools::tags$p(body)
  )
}

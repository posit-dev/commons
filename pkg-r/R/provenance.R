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
  trigger <- htmltools::tags$button(
    type = "button",
    class = "commons-provenance-info-trigger",
    `aria-label` = "How answer trust is determined",
    htmltools::tags$span(`aria-hidden` = "true", "i")
  )

  htmltools::tags$div(
    class = "commons-provenance-info",
    trigger,
    htmltools::tags$div(
      class = "commons-provenance-info-content",
      hidden = NA,
      provenance_info_modal()
    )
  )
}

provenance_info_modal <- function() {
  htmltools::tags$div(
    class = "commons-provenance-info-modal modal fade",
    tabindex = "-1",
    `aria-label` = "How answer trust is determined",
    `aria-hidden` = "true",
    htmltools::tags$div(
      class = paste(
        "modal-dialog modal-dialog-centered",
        "modal-dialog-scrollable"
      ),
      htmltools::tags$div(
        class = "modal-content",
        htmltools::tags$div(
          class = "modal-header",
          htmltools::tags$h2(
            class = "modal-title",
            "How answer trust is determined"
          ),
          htmltools::tags$button(
            type = "button",
            class = "btn-close",
            `data-bs-dismiss` = "modal",
            `aria-label` = "Close"
          )
        ),
        htmltools::tags$div(
          class = "modal-body",
          provenance_info_body()
        )
      )
    )
  )
}

provenance_info_body <- function() {
  htmltools::tags$div(
    class = "commons-provenance-info-body",
    htmltools::tags$p(
      paste(
        "This application asks an AI agent to use trusted calculations",
        "whenever possible. When no relevant calculation is available, the",
        "agent may write code itself. commons determines the provenance",
        "outcome from the path the agent took."
      )
    ),
    htmltools::tags$ul(
      class = "commons-provenance-info-list",
      provenance_info_item("A", "trusted-icon.svg"),
      provenance_info_item(
        "B",
        "citation-mark.svg",
        paste(
          provenance_display$B$body,
          "The custom calculation itself was not vetted."
        )
      ),
      provenance_info_item("C", "warning-icon.svg"),
      provenance_info_item(
        label = "No marker",
        body = paste(
          "No data tool was used for this answer, so commons assigns no",
          "provenance outcome. This is not equivalent to a Verified answer."
        )
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
      "—"
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

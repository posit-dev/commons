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

# The aside body is rendered by shinychat long after page load, so the
# trigger is a web component (see inst/www/commons-chat/commons-chat.js):
# it renders its own button and opens the shared offcanvas explainer panel,
# with no Shiny wiring or mount-order assumptions on the R side.
provenance_info_control <- function() {
  '<commons-provenance-info class="commons-provenance-info"></commons-provenance-info>'
}

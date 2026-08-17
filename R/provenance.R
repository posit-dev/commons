provenance_display <- list(
  A = list(
    label = "Verified answer",
    icon = "trusted-icon.svg",
    body = paste(
      "This answer comes from a governed calculation defined by",
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
      "This answer was not produced by a governed calculation and has",
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

provenance_aside <- function(tag) {
  entry <- provenance_display[[tag]]
  if (is.null(entry) || identical(tag, "B")) {
    return("")
  }
  icon <- commons_icon_url(entry$icon)
  sprintf(
    '<shiny-aside label="%s"%s>%s</shiny-aside>',
    escape_attr(entry$label),
    if (is.null(icon)) "" else sprintf(' icon="%s"', escape_attr(icon)),
    entry$body
  )
}

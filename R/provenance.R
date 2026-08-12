# Copy and icon for each provenance tag, keyed the same way as the tag
# itself. "B" has no entry here: a cited answer's provenance UI is the
# citation asides render_citation_aside() builds, not a pill.
provenance_display <- list(
  A = list(
    label = "Verified answer",
    icon = "trusted-icon.svg",
    body = paste(
      "This answer comes from a governed calculation defined by",
      "your data team."
    )
  ),
  C = list(
    label = "Untrusted",
    icon = "warning-icon.svg",
    body = paste(
      "This answer was not produced by a governed calculation and has",
      "no verified supporting citation. AI can be wrong."
    )
  )
)

# "B" beats "A": a governed calculation that also cites trusted text still
# reads as untrusted unless the citation checks out, because the citation is
# the thing the user is meant to trust. Neither tag present means nothing to
# show.
derive_provenance_tag <- function(tags, verified) {
  if ("B" %in% tags) {
    if (verified) "B" else "C"
  } else if ("A" %in% tags) {
    "A"
  } else {
    NA_character_
  }
}

# A provenance pill for "A"/"C" as <shiny-aside> markup; "" for "B" (whose UI
# is the citation asides) and NA (nothing to show).
provenance_aside <- function(tag) {
  entry <- provenance_display[[tag]]
  if (is.null(entry)) {
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

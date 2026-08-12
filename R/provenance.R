# Copy, icon, and pill styling for each provenance tag, keyed the same way
# as the tag itself. Shared by provenance_aside() (the shiny-aside markdown
# shown inline for A/C) and commons_answer_pill() (R/trajectory-review.R;
# the compact question-list badge for A/B/C). "B" gets no *aside* here -- a
# cited answer's provenance UI there is the citation asides
# render_citation_aside() builds, not a pill -- but it still needs pill
# copy, so its entry stays in this table and provenance_aside() excludes it
# explicitly.
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

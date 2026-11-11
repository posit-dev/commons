provenance_display <- list(
  A = list(
    label = "Trusted",
    icon = "trusted-icon.svg",
    body = "This answer comes from a trusted calculation."
  ),
  B = list(
    label = "Cited",
    icon = NULL,
    body = paste(
      "This answer cites context from a trusted source that supports",
      "its approach."
    )
  ),
  C = list(
    label = "Untrusted",
    icon = "warning-icon.svg",
    body = paste(
      "This answer was not produced by a trusted calculation and does not",
      "cite trusted context."
    )
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

# Verified citation asides already identify cited answers.
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
    paste(entry$body, as.character(provenance_info_control()))
  )
}

# Custom elements upgrade when shinychat mounts the aside after page load.
provenance_info_control <- function() {
  '<commons-provenance-info class="commons-provenance-info"></commons-provenance-info>'
}

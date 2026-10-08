# Temporary: shinychat saves history as the model's turns rather than the
# messages it displayed, so a restored conversation would show raw citation
# and document markup. Each assistant text carries its display alongside; the
# provider still sends `text`. Remove once posit-dev/shinychat#379 lands.
ContentDisplayText <- S7::new_class(
  "ContentDisplayText",
  parent = ellmer::ContentText,
  properties = list(display = S7::class_character)
)

S7::method(contents_shinychat, ContentDisplayText) <- function(content) {
  content@display
}

# Re-projects each new assistant text the way the stream did. `links` holds
# what the live stream put in place of each document, in order, so documents
# aren't saved a second time; the provenance aside follows the last text.
with_display_text <- function(turns, from_index, corpus, links, aside = "") {
  replay_link <- function(event) {
    if (!identical(event$type, "close") || length(links) == 0) {
      return(NULL)
    }
    link <- links[[1]]
    links <<- links[-1]
    link
  }

  last <- NULL
  for (i in seq_along(turns)[seq_along(turns) >= from_index]) {
    turn <- turns[[i]]
    if (!S7::S7_inherits(turn, ellmer::AssistantTurn)) {
      next
    }
    for (j in seq_along(turn@contents)) {
      content <- turn@contents[[j]]
      if (!identical(S7::S7_class(content), ellmer::ContentText)) {
        next
      }
      scanner <- citation_scanner(corpus, on_artifact = replay_link)
      turn@contents[[j]] <- ContentDisplayText(
        text = content@text,
        display = paste0(scanner$feed(content@text), scanner$finish())
      )
      last <- c(i, j)
    }
    turns[[i]] <- turn
  }

  if (!is.null(last) && nzchar(aside)) {
    content <- turns[[last[[1]]]]@contents[[last[[2]]]]
    content@display <- paste0(content@display, aside)
    turns[[last[[1]]]]@contents[[last[[2]]]] <- content
  }
  turns
}

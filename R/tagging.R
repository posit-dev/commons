# Exchange-level provenance: "A" when every data-returning tool call was a
# registered measure, "B" when fallback tools ran but the answer carries a
# verified citation, "C" when fallback tools ran and it doesn't. `citations`
# holds every citation the answer attempted, in order, so the client can
# replace their rendered markup positionally.
derive_provenance <- function(tags, text = character(), corpus = list()) {
  if (!("B" %in% tags)) {
    tag <- if ("A" %in% tags) "A" else NA_character_
    return(list(tag = tag, citations = list()))
  }
  citations <- answer_citations(text, corpus)
  verified <- any(vapply(citations, function(x) x$verified, logical(1)))
  list(tag = if (verified) "B" else "C", citations = citations)
}

commons_last_provenance <- function(client) {
  provenances <- commons_exchange_provenance(
    client$get_turns(include_system_prompt = FALSE),
    client$citation_corpus()
  )
  if (length(provenances) == 0) {
    return(derive_provenance(character()))
  }
  provenances[[length(provenances)]]
}

# Provenance for each completed question -> answer exchange, in order. Used to
# reinstate provenance pills when an existing conversation seeds a new
# session, since pills are otherwise only injected as live turns complete.
commons_exchange_provenance <- function(turns, corpus = list()) {
  out <- list()
  tags <- character()
  text <- character()
  started <- FALSE
  for (turn in turns) {
    if (identical(turn@role, "user") && !turn_has_tool_result(turn)) {
      if (started) {
        out[[length(out) + 1]] <- derive_provenance(tags, text, corpus)
      }
      tags <- character()
      text <- character()
      started <- TRUE
    } else if (started) {
      tags <- c(tags, turn_tags(turn))
      text <- c(text, turn_text(turn))
    }
  }
  if (started) {
    out[[length(out) + 1]] <- derive_provenance(tags, text, corpus)
  }
  out
}

turn_has_tool_result <- function(turn) {
  any(vapply(turn@contents, is_tool_result_content, logical(1)))
}

turn_tags <- function(turn) {
  unlist(
    lapply(turn@contents, function(content) {
      if (is_tool_result_content(content)) {
        content@extra$commons_tag
      }
    }),
    use.names = FALSE
  )
}

turn_text <- function(turn) {
  if (!identical(turn@role, "assistant")) {
    return(character())
  }
  unlist(
    lapply(turn@contents, function(content) {
      if (S7::S7_inherits(content, ellmer::ContentText)) {
        content@text
      }
    }),
    use.names = FALSE
  )
}

is_tool_result_content <- function(content) {
  S7::S7_inherits(content, ellmer::ContentToolResult)
}

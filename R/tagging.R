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
  lapply(split_exchanges(turns), function(exchange) {
    derive_provenance(
      unlist(lapply(exchange, turn_tags)) %||% character(),
      unlist(lapply(exchange, turn_text)) %||% character(),
      corpus
    )
  })
}

# Turns split into question -> answer exchanges: each exchange opens at a
# user turn carrying no tool results and runs until the next one. Turns
# before the first such user turn (e.g. system turns) belong to no exchange.
split_exchanges <- function(turns) {
  out <- list()
  current <- NULL
  for (turn in turns) {
    if (identical(turn@role, "user") && !turn_has_tool_result(turn)) {
      if (!is.null(current)) {
        out[[length(out) + 1]] <- current
      }
      current <- list(turn)
    } else if (!is.null(current)) {
      current[[length(current) + 1]] <- turn
    }
  }
  if (!is.null(current)) {
    out[[length(out) + 1]] <- current
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

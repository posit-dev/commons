# Fallback answers can cite the trusted text that backs them: the model ends
# its reply with <citation reason="...">exact text</citation> elements, and
# commons verifies each quote against the corpus of text the agent could have
# drawn on. Only the quote is verified; the reason is unverified model
# commentary shown alongside it. See derive_provenance() for how verification
# affects an answer's provenance tag.

# Everything citable: context layer docs, always-on facts, measure schemas
# (as search_measures presents them), and dictionary entries (as first touch
# delivers them). Labels are user-facing; they name the source in a footnote
# tooltip.
build_citation_corpus <- function(context_layer, registry, sources) {
  corpus <- list()
  add <- function(label, text) {
    for (t in text[nzchar(text)]) {
      corpus[[length(corpus) + 1]] <<- list(label = label, text = t)
    }
    invisible()
  }

  add("context layer", context_layer$docs %||% character())
  add("context layer", context_layer$always %||% character())
  # Mirror tool_search_measures(): source lines only appear in schemas when
  # the agent has several sources, and quotes must match what was presented.
  source_names <- if (length(sources) > 1) names(sources) else character()
  for (td in registry) {
    add(
      sprintf("measure '%s'", tool_name(td)),
      measure_schema_text(td, source_names = source_names)
    )
  }
  for (i in seq_along(sources)) {
    dictionary <- sources[[i]]$dictionary
    add(
      "data dictionary",
      c(
        dictionary$description %||% character(),
        dictionary$details %||% character()
      )
    )
    for (table in names(dictionary$tables)) {
      add(
        sprintf("data dictionary, table '%s'", table),
        dictionary_entry_text(dictionary, table) %||% character()
      )
    }
  }
  corpus
}

# Extraction mirrors how the browser will parse the markup, since the client
# replaces the rendered elements positionally: markup inside code (which never
# becomes an element) is skipped, and tag-name case, attributes, and
# whitespace are tolerated the way an HTML parser tolerates them.
extract_citations <- function(text) {
  if (length(text) == 0) {
    return(list())
  }
  text <- paste(text, collapse = "\n")
  text <- gsub("(?s)```.*?```", "", text, perl = TRUE)
  text <- gsub("`[^`\n]*`", "", text)
  matches <- regmatches(
    text,
    gregexpr("(?si)<citation\\b[^>]*>.*?</citation\\s*>", text, perl = TRUE)
  )[[1]]
  lapply(matches, function(match) {
    opening <- regmatches(
      match,
      regexpr("(?i)^<citation\\b[^>]*>", match, perl = TRUE)
    )
    quote <- sub("(?i)^<citation\\b[^>]*>", "", match, perl = TRUE)
    list(
      quote = sub("(?i)</citation\\s*>$", "", quote, perl = TRUE),
      reason = citation_reason(opening)
    )
  })
}

citation_reason <- function(opening) {
  match <- regmatches(
    opening,
    regexec("(?i)\\breason\\s*=\\s*(\"[^\"]*\"|'[^']*')", opening, perl = TRUE)
  )[[1]]
  if (length(match) == 0) {
    return(NA_character_)
  }
  value <- match[[2]]
  trimws(substr(value, 2, nchar(value) - 1))
}

# All extracted citations, each verified against the corpus. Unverified
# entries and their order are kept for the client's positional replacement of
# the rendered <citation> elements (see applyCitations in commons-chat.js).
answer_citations <- function(text, corpus) {
  lapply(extract_citations(text), function(citation) {
    label <- match_citation(citation$quote, corpus)
    list(
      quote = citation$quote,
      reason = citation$reason,
      label = label,
      verified = !is.na(label)
    )
  })
}

match_citation <- function(quote, corpus) {
  needle <- normalize_citation(quote)
  # A trivial quote shouldn't be able to promote an answer.
  if (nchar(needle) < 10) {
    return(NA_character_)
  }
  for (entry in corpus) {
    if (grepl(needle, normalize_citation(entry$text), fixed = TRUE)) {
      return(entry$label)
    }
  }
  NA_character_
}

# Forgiving of the ways a faithful quote can still drift from its source:
# reflowed whitespace, markdown emphasis, and typographic quotes/dashes.
normalize_citation <- function(x) {
  x <- gsub("[*_`]", "", x)
  x <- gsub("[\u2018\u2019]", "'", x)
  x <- gsub("[\u201c\u201d]", "\"", x)
  x <- gsub("[\u2013\u2014]", "-", x)
  trimws(gsub("\\s+", " ", x))
}

# The citation request rides on the first fallback-tagged tool result of the
# conversation rather than living in the system prompt, so conversations
# answered entirely by measures never see it.
add_citation_request <- function(result, tracker) {
  if (is.null(tracker) || isTRUE(tracker$requested)) {
    return(result)
  }
  tracker$requested <- TRUE

  request <- citation_request_text()
  if (is.character(result@value)) {
    result@value <- paste(c(result@value, request), collapse = "\n\n")
  } else {
    result@value <- c(result@value, list(ellmer::ContentText(text = request)))
  }
  result
}

citation_request_text <- function() {
  paste(
    readLines(
      system.file("prompts/citation-request.md", package = "commons"),
      warn = FALSE
    ),
    collapse = "\n"
  )
}

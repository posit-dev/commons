# Explanations remain model-authored, so only citation quotes affect provenance.

# Matching returns the first source containing a quote, so add specific
# sources before the general documentation corpus.
build_citation_corpus <- function(context_layer, registry, sources) {
  corpus <- list()
  add <- function(label, kind, text) {
    for (t in text[nzchar(text)]) {
      corpus[[length(corpus) + 1]] <<- list(
        label = label,
        kind = kind,
        text = t
      )
    }
    invisible()
  }

  # Mirror search_pool's measure blocks: source lines only appear in schemas when
  # the agent has several sources, and quotes must match what was presented.
  source_names <- if (length(sources) > 1) names(sources) else character()
  for (td in registry) {
    add(
      sprintf("%s definition", tool_name(td)),
      "definition",
      measure_schema_text(td, source_names = source_names)
    )
  }
  names_out <- rlang::names2(sources)
  for (i in seq_along(sources)) {
    dictionary <- sources[[i]]$dictionary
    add(
      if (nzchar(names_out[[i]])) {
        sprintf("%s dictionary", names_out[[i]])
      } else {
        "data dictionary"
      },
      "schema",
      c(
        dictionary$description %||% character(),
        dictionary$details %||% character()
      )
    )
    for (table in names(dictionary$tables)) {
      add(
        sprintf("%s table", table),
        "schema",
        dictionary_entry_text(dictionary, table) %||% character()
      )
    }
  }
  add("documentation", "prose", context_layer$docs %||% character())
  corpus
}

match_citation <- function(quote, corpus) {
  needle <- normalize_citation(quote)
  # Reject trivial matches that could promote an unsupported answer.
  if (nchar(needle) < 10) {
    return(NULL)
  }
  for (entry in corpus) {
    if (grepl(needle, normalize_citation(entry$text), fixed = TRUE)) {
      return(list(label = entry$label, kind = entry$kind))
    }
  }
  NULL
}

# Only the quote is verified; the explanation remains model-authored.
render_citation_aside <- function(quote, explanation, corpus) {
  source <- match_citation(quote, corpus)
  decision <- list(
    quote = quote,
    status = if (is.null(source)) "rejected" else "accepted"
  )
  if (is.null(source)) {
    return(list(html = "", decision = decision))
  }
  decision$label <- source$label
  decision$kind <- source$kind
  list(
    html = citation_aside_html(
      quote,
      explanation,
      source$label,
      source$kind
    ),
    decision = decision
  )
}

citation_aside_html <- function(quote, explanation, label, kind) {
  icon <- citation_icon_url(kind)
  reason <- if (nzchar(explanation)) paste0(explanation, "\n\n") else ""
  blockquote <- paste0("> ", gsub("\n", "\n> ", trimws(quote), fixed = TRUE))
  sprintf(
    paste0(
      '<shiny-aside display="compact" label="%s"%s>',
      "%s%s</shiny-aside>"
    ),
    escape_attr(label),
    if (is.null(icon)) "" else sprintf(' icon="%s"', escape_attr(icon)),
    reason,
    blockquote
  )
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

# The citation contract is in the system prompt. The first fallback-tagged tool
# result in each user turn carries a short reminder.
add_citation_request <- function(result, tracker) {
  if (is.null(tracker) || isTRUE(tracker$requested)) {
    return(result)
  }
  tracker$requested <- TRUE

  request <- tracker$reminder %||% citation_reminder_text()
  if (is.character(result@value)) {
    result@value <- paste(c(result@value, request), collapse = "\n\n")
  } else {
    result@value <- c(result@value, list(ellmer::ContentText(text = request)))
  }
  result
}

citation_reminder_text <- function() {
  paste(
    "With this most recent tool call, this turn is now based on outputs",
    "beyond trusted calculations.",
    "If trusted text you have seen supports your final answer,",
    "add a `<commons-citation>` block with one blockquote of the exact",
    "supporting text, following the citation rules given earlier.",
    "Otherwise, provide no citations."
  )
}

citation_trust_exception <- function(tools) {
  trusted_path_tools <- intersect(
    tools,
    c("search_pool", "call_measure", "call_metrics", "call_calculation")
  )
  if (!length(trusted_path_tools)) {
    return("")
  }
  names <- sprintf("`%s`", trusted_path_tools)
  paste0(
    " that is not based solely on output from ",
    paste(names, collapse = " or ")
  )
}

available_tool_names <- function(tools) {
  if (is.character(tools)) {
    return(tools)
  }
  vapply(tools, tool_name, character(1))
}

citable_tool_output_text <- function(tools) {
  items <- c(
    "- Data-dictionary prose shown in this system prompt.",
    if ("search_pool" %in% tools) {
      paste(
        "- From `search_pool`: measure definitions; descriptions, SQL",
        "expressions, and translation notes for governed definitions."
      )
    },
    if ("search_context" %in% tools) {
      "- From `search_context`: trusted context excerpts."
    },
    if ("describe_table" %in% tools) {
      paste(
        "- From `describe_table`: data-dictionary descriptions, details,",
        "documented columns, definitions, relationships, and terms."
      )
    },
    if ("run_sql" %in% tools) {
      paste(
        "- From `run_sql`: data-dictionary entries appended after the query",
        "result."
      )
    }
  )
  paste(items, collapse = "\n")
}

non_citable_tool_output_text <- function(tools) {
  items <- c(
    if ("describe_table" %in% tools) {
      paste(
        "- Live relation metadata, inferred schema, and sample rows from",
        "`describe_table`."
      )
    },
    if ("call_measure" %in% tools) {
      paste(
        "- Result values from `call_measure`. An answer based on that tool",
        "alone is already trusted and needs no citation."
      )
    },
    if ("call_metrics" %in% tools) {
      paste(
        "- Result values from `call_metrics`. An answer based on that tool",
        "alone is already trusted and needs no citation."
      )
    },
    if ("call_calculation" %in% tools) {
      paste(
        "- Result values from `call_calculation`. An answer based on that tool",
        "alone is already trusted and needs no citation."
      )
    },
    if ("run_sql" %in% tools) "- Query result rows from `run_sql`.",
    if ("run_r" %in% tools) {
      "- Code, measure source, plots, and textual output from `run_r`."
    }
  )
  paste(items, collapse = "\n")
}

# These SVGs need a fixed stroke because images cannot inherit currentColor.
COMMONS_ICON_RESOURCE_PREFIX <- "commons-icons"

citation_icon_url <- function(kind) {
  file <- switch(
    kind,
    prose = "citation-prose.svg",
    definition = "citation-definition.svg",
    schema = "citation-schema.svg",
    NULL
  )
  if (is.null(file)) {
    return(NULL)
  }
  commons_icon_url(file)
}

commons_icon_url <- function(file) {
  if (is.null(commons_icon_path(file))) {
    return(NULL)
  }
  paste0(
    COMMONS_ICON_RESOURCE_PREFIX,
    "/",
    utils::URLencode(file, reserved = TRUE)
  )
}

# Escape ampersands first to avoid re-escaping generated entities.
escape_attr <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  gsub("\"", "&quot;", x, fixed = TRUE)
}

# The trajectory reviewer does not register the live chat's resource path.
svg_data_uri <- function(file) {
  path <- commons_icon_path(file)
  if (is.null(path)) {
    return(NULL)
  }
  svg <- paste(readLines(path, warn = FALSE), collapse = "\n")
  svg <- sub("^\\s*<\\?xml[^>]*\\?>\\s*", "", svg)
  paste0("data:image/svg+xml,", utils::URLencode(svg, reserved = TRUE))
}

commons_icon_path <- function(file) {
  path <- system.file("figs", file, package = "commons")
  if (!nzchar(path)) NULL else path
}

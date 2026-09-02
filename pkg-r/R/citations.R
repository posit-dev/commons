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
    source_state <- data_source_state(sources[[i]])
    dictionary <- source_state$dictionary
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
  context <- if (is.null(context_layer)) NULL else context_layer_state(context_layer)
  add("documentation", "prose", context$docs %||% character())
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
  # The pill renders the uniform quote mark; the per-kind icon goes in
  # the body title (commons-chat.css hides shinychat's popover title row,
  # so the aside's icon attribute is only a styling hook for the pill).
  icon <- commons_icon_url("citation-mark.svg")
  kind_icon <- citation_icon_url(kind)
  reason <- if (nzchar(explanation)) paste0(explanation, "\n\n") else ""
  blockquote <- paste0("> ", gsub("\n", "\n> ", trimws(quote), fixed = TRUE))
  # shinychat only renders the popover's title row for grouped asides, so
  # the body carries its own title (icon + label) to keep the source named
  # for singleton citations; commons-chat.css hides shinychat's row.
  title <- sprintf(
    paste0(
      '<span class="commons-citation-title">',
      '%s<span class="commons-citation-title-label">%s</span></span>\n\n'
    ),
    if (is.null(kind_icon)) {
      ""
    } else {
      sprintf('<img src="%s" alt="">', escape_attr(kind_icon))
    },
    htmltools::htmlEscape(label)
  )
  sprintf(
    paste0(
      '<shiny-aside label="%s"%s>',
      "%s%s%s</shiny-aside>"
    ),
    escape_attr(label),
    if (is.null(icon)) "" else sprintf(' icon="%s"', escape_attr(icon)),
    title,
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
  read_prompt("citation-request.md")
}

citation_trust_exception <- function(tools) {
  trusted_path_tools <- intersect(TRUSTED_TOOLS, tools)
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

# Which outputs are citable depends on which tools the agent registered, so the
# template branches on one flag per tool. The order here is the order the
# citation sections read in, not the order tools are registered.
TRUSTED_TOOLS <- c(
  "search_pool",
  "call_measure",
  "call_metrics",
  "call_calculation"
)

CITED_TOOLS <- c(
  "search_pool",
  "search_context",
  "describe_table",
  "run_sql",
  "call_measure",
  "call_metrics",
  "call_calculation",
  "run_r"
)

tool_availability <- function(tools) {
  stats::setNames(as.list(CITED_TOOLS %in% tools), paste0("has_", CITED_TOOLS))
}

# The per-kind icon appears in the aside body's title; the pill renders
# the uniform citation-mark.svg quote mark instead. These SVGs need a
# fixed stroke because images cannot inherit currentColor.
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

# Icons are served by the commons-chat HTML dependency (see
# commons_theme()), so their URLs carry the dependency's version.
commons_icon_url <- function(file) {
  if (is.null(commons_icon_path(file))) {
    return(NULL)
  }
  dep <- commons_chat_dependency()
  paste0(
    dep$name,
    "-",
    dep$version,
    "/figs/",
    utils::URLencode(file, reserved = TRUE)
  )
}

# Escape ampersands first to avoid re-escaping generated entities.
escape_attr <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  gsub("\"", "&quot;", x, fixed = TRUE)
}

commons_icon_path <- function(file) {
  path <- system.file("www", "commons-chat", "figs", file, package = "commons")
  if (!nzchar(path)) NULL else path
}

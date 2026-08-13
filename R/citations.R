# Fallback answers can cite the trusted text that backs them: the model ends
# its reply with <citation reason="...">exact text</citation> elements, and
# commons verifies each quote against the corpus of text the agent could have
# drawn on. Only the quote is verified; the reason is unverified model
# commentary shown alongside it. See derive_provenance_tag() for how
# verification affects an answer's provenance tag.

# Everything citable: measure schemas (as search_pool presents them),
# dictionary entries (as first touch delivers them), and the context layer's
# docs. Each entry carries a `kind` -- "prose", "definition", or "schema" --
# which selects the aside's icon, and a `label` naming the specific source.
# Labels are noun phrases because the aside pill's accessible name is the
# label and nothing else: its icon is decorative, so "sales" alone would tell
# a screen reader nothing.
#
# Order here is precedence, not presentation. match_citation() reports the
# first entry whose text contains the quote, and augment_context_layer()
# copies dictionary prose into the context store to make it searchable -- so
# a table's own description is reachable under both its table label and the
# catch-all documentation label. Specific sources are added first so the
# reader is always pointed at the narrowest source that can account for the
# quote.
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

# The label/kind of the first corpus entry containing `quote`, or NULL when
# nothing does.
match_citation <- function(quote, corpus) {
  needle <- normalize_citation(quote)
  # A trivial quote shouldn't be able to promote an answer.
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

# One verified citation as <shiny-aside> markup. The icon says what sort of
# source this is and the label says which one, which is what lets the label
# stay short. The "matched exactly" line stays in the popover body, off the
# pill face where it would read as a trust badge. An unverified quote
# contributes nothing: a pill for an unconfirmed quote would misrepresent it.
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
  reason <- if (nzchar(explanation)) paste0("**", explanation, "**\n\n") else ""
  blockquote <- paste0("> ", gsub("\n", "\n> ", trimws(quote), fixed = TRUE))
  sprintf(
    '<shiny-aside label="%s"%s>%s> %s\n\n*Quoted verbatim; matched exactly.*</shiny-aside>',
    escape_attr(label),
    if (is.null(icon)) "" else sprintf(' icon="%s"', escape_attr(icon)),
    reason,
    blockquote
  )
}

render_recorded_citation_aside <- function(parsed, decision) {
  fallback <- list(
    quote = if (is.null(parsed)) NA_character_ else parsed$quote,
    status = "missing"
  )
  if (is.null(parsed) || is.null(decision) || !is.list(decision)) {
    return(list(html = "", decision = fallback))
  }
  valid <- is.character(parsed$quote) &&
    length(parsed$quote) == 1 &&
    is.character(parsed$explanation) &&
    length(parsed$explanation) == 1 &&
    identical(decision$status %||% "", "accepted") &&
    is.character(decision$quote) &&
    length(decision$quote) == 1 &&
    identical(
      normalize_citation(parsed$quote),
      normalize_citation(decision$quote)
    ) &&
    is.character(decision$label) &&
    length(decision$label) == 1 &&
    nzchar(decision$label) &&
    is.character(decision$kind) &&
    length(decision$kind) == 1 &&
    decision$kind %in% c("prose", "definition", "schema")
  if (!valid) {
    return(list(html = "", decision = decision))
  }
  list(
    html = citation_aside_html(
      parsed$quote,
      parsed$explanation,
      decision$label,
      decision$kind
    ),
    decision = decision
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

# The full citation request rides on the conversation's first fallback-tagged
# tool result; later user turns get a shorter reminder on their first fallback.
# Conversations answered entirely by governed tools never see either prompt.
add_citation_request <- function(result, tracker) {
  if (is.null(tracker) || isTRUE(tracker$requested)) {
    return(result)
  }
  tracker$requested <- TRUE

  if (isTRUE(tracker$full_sent)) {
    request <- tracker$reminder %||% citation_reminder_text()
  } else {
    request <- tracker$request %||% citation_request_text()
    tracker$full_sent <- TRUE
  }
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

citation_request_text <- function(measures = list(), definitions = NULL) {
  has_measures <- length(measures) > 0
  has_definitions <- !is.null(definitions) &&
    nrow(registry_defs(definitions)) > 0

  # Without a tool that answers on its own (call_measure, call_metrics),
  # every answer is a fallback answer: there is no governed path to contrast
  # with, so don't imply one.
  exception <- if (has_measures || registry_has_metrics(definitions)) {
    " that does not come from a trusted calculation alone"
  }
  trust_note <- cli::format_inline(
    'Note: any answer in this conversation{exception} will be presented to
     the user as "Untrusted" unless you cite trusted text that supports your
     approach.'
  )
  citable <- c(
    "context search results",
    if (has_measures) "measure definitions",
    if (has_definitions) "governed definitions",
    "data documentation"
  )
  as.character(ellmer::interpolate_file(
    system.file("prompts/citation-request.md", package = "commons"),
    trust_note = trust_note,
    citable_sources = cli::format_inline("{.or {citable}}")
  ))
}

# Glyph per citation kind. The SVGs carry a literal stroke colour because the
# icon renders as <img>, which cannot inherit currentColor.
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

# Minimal escaping for a value interpolated into an HTML attribute. Order
# matters: escaping "&" first keeps "&quot;" itself from being re-escaped.
escape_attr <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  gsub("\"", "&quot;", x, fixed = TRUE)
}

# svg_data_uri() self-embeds the SVG rather than pointing at
# commons_icon_url()'s resource path because its caller (the trajectory
# review app) never calls register_commons_icon_resources() -- that
# happens in commons_ui(), a different Shiny app.
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

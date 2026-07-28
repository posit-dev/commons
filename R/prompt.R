commons_system_prompt <- function(
  sources,
  system_prompt,
  definitions = NULL,
  measures = list()
) {
  definitions <- definitions %||% definitions_registry(sources)
  paste0(
    trimws(system_prompt, which = "right"),
    how_to_answer_text(measures, definitions),
    "\n\n# Available tables\n\n",
    sources_tables_text(sources),
    "\n",
    dictionary_prompt_text(sources),
    definitions_prompt_text(definitions)
  )
}

# Assembled from the agent's composition rather than written in the packaged
# prompt file, so the workflow never contradicts the tools the agent has.
how_to_answer_text <- function(measures, definitions) {
  has_measures <- length(measures) > 0
  fallback <- paste0(
    "search context with `search_context`, inspect relevant tables with ",
    "`describe_table`, then run a read-only query with `run_sql`."
  )
  invoke <- c(
    if (has_measures) "run a measure with `call_measure`",
    if (registry_has_metrics(definitions)) {
      "compute a metric with `call_metrics`"
    },
    if (nrow(registry_defs(definitions)) > 0) {
      "apply a definition as a `{{name}}` token in `run_sql` SQL"
    }
  )

  workflow <- if (length(invoke) == 0) {
    paste0("Search", substring(fallback, nchar("search") + 1))
  } else {
    c(
      paste0(
        "Governed operations are the preferred way to answer data ",
        "questions: ",
        cli::format_inline("{invoke}"),
        ". ",
        if (pool_searchable(measures, definitions)) {
          paste0(
            "For any question that needs data, your first tool call must be ",
            "`search_pool` with the user's question — do this even if a ",
            "table looks easy to query directly, and use the exact names it ",
            "returns. Do not call `run_sql` or `describe_table` until after ",
            "you have."
          )
        } else {
          "Every name you can use is indexed below."
        }
      ),
      paste0("When nothing governed answers the question, ", fallback)
    )
  }

  derive <- paste0(
    "Query results are stored under handles (`r1`, `r2`, ...) and preloaded ",
    "into the `run_r` R session. When a result is close to the answer but ",
    "needs a further derivation — a filter, total, ratio, or ranking — ",
    "call `run_r` on the stored handle rather than re-deriving it in SQL. ",
    if (has_measures) {
      "Prefer a measure's own arguments when they can answer it directly. "
    },
    "When a chart would communicate the answer better than text, render ",
    "one with `run_r`; plots are shown to the user."
  )

  paste0(
    "\n\n# How to answer\n\n",
    paste(c(workflow, derive), collapse = "\n\n")
  )
}

check_system_prompt <- function(system_prompt, call = rlang::caller_env()) {
  rlang::check_string(system_prompt, call = call)
  # A path here would silently become the literal prompt text.
  if (!grepl("\n", system_prompt, fixed = TRUE) && file.exists(system_prompt)) {
    suggestion <- sprintf('ellmer::interpolate_file("%s")', system_prompt)
    cli::cli_abort(
      c(
        "{.arg system_prompt} must be prompt content, not a file path.",
        i = "Did you mean {.code {suggestion}}?"
      ),
      call = call
    )
  }
  invisible(system_prompt)
}

# Only dataset-wide dictionary content is ambient: description and details
# (global guardrails, coarse routing) and the glossary up to a cap. Per-table
# content is delivered at first touch instead; see dictionary_entry_text().
dictionary_prompt_text <- function(sources) {
  blocks <- character()
  for (i in seq_along(sources)) {
    dictionary <- sources[[i]]$dictionary
    if (is.null(dictionary)) {
      next
    }
    label <- if (length(sources) > 1) {
      rlang::names2(sources)[[i]]
    } else {
      dictionary$name %||% ""
    }
    blocks <- c(blocks, dictionary_prompt_block(dictionary, label))
  }

  if (length(blocks) == 0) {
    return("")
  }
  paste0("\n# About the data\n\n", paste(blocks, collapse = "\n\n"))
}

dictionary_prompt_block <- function(dictionary, label) {
  ambient <- glossary_ambient(dictionary)
  glossary <- if (length(ambient)) {
    lines <- sprintf(
      "- %s: %s",
      ambient,
      vapply(dictionary$glossary[ambient], flatten_inline, character(1))
    )
    paste0("Definitions of domain terms:\n\n", paste(lines, collapse = "\n"))
  }

  parts <- c(
    if (nzchar(label)) sprintf("## %s", label),
    dictionary$description,
    dictionary$details,
    glossary
  )
  paste(parts, collapse = "\n\n")
}

# One source keeps the flat bullet list; several group each source's tables
# under a heading with a dialect hint, plus a note on the `source` argument.
sources_tables_text <- function(sources) {
  if (length(sources) == 1) {
    return(table_bullets(sources[[1]]))
  }

  blocks <- vapply(
    names(sources),
    function(name) {
      sprintf(
        "## %s (%s)\n\n%s",
        name,
        source_dialect(sources[[name]]),
        table_bullets(sources[[name]])
      )
    },
    character(1)
  )
  paste0(
    "Tables are grouped by data source. Pass the source's name as `source` ",
    "to `describe_table` and `run_sql`.\n\n",
    paste(blocks, collapse = "\n\n")
  )
}

table_bullets <- function(source) {
  paste(sprintf("- %s", list_tables(source)), collapse = "\n")
}

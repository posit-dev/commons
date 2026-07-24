# Everything whose presence depends on the agent's composition is appended
# here rather than written in the packaged prompt file: guidance for
# registered measures only when the agent has measures, governed definitions
# only when its dictionaries declare them. An agent's prompt should never
# imply operations it doesn't have.
commons_system_prompt <- function(
  sources,
  system_prompt,
  definitions = NULL,
  measures = list()
) {
  paste0(
    trimws(system_prompt, which = "right"),
    measures_prompt_text(measures),
    "\n\n# Available tables\n\n",
    sources_tables_text(sources),
    "\n",
    dictionary_prompt_text(sources),
    definitions_prompt_text(definitions %||% definitions_registry(sources))
  )
}

measures_prompt_text <- function(measures) {
  if (length(measures) == 0) {
    return("")
  }
  paste0(
    "\n\n# Registered measures\n\n",
    "Registered measures are the preferred way to answer data questions. ",
    "For any question that needs data, your first tool call must be ",
    "`search_pool` with the user's question. Do this even if a table ",
    "looks easy to query directly. If `search_pool` returns a relevant ",
    "measure, call `call_measure` with the exact measure name and argument ",
    "names returned by `search_pool`.\n\n",
    "Do not call `run_sql` or `describe_table` until after you have called ",
    "`search_pool` for the user's question. Use SQL only when ",
    "`search_pool` does not return a relevant measure. When a measure ",
    "output is close to the answer but needs a further derivation, call ",
    "`run_r` on its stored handle rather than rewriting the governed logic ",
    "with `run_sql`, and prefer the measure's own arguments when they can ",
    "answer the question directly."
  )
}

check_system_prompt <- function(system_prompt, call = rlang::caller_env()) {
  if (!rlang::is_string(system_prompt)) {
    cli::cli_abort(
      "{.arg system_prompt} must be a single string, e.g. from
       {.fn ellmer::interpolate_file}.",
      call = call
    )
  }
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


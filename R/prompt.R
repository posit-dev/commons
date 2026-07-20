commons_system_prompt <- function(sources, system_prompt) {
  paste0(
    trimws(system_prompt, which = "right"),
    "\n\n# Available tables\n\n",
    sources_tables_text(sources),
    "\n",
    dictionary_prompt_text(sources)
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


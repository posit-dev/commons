commons_system_prompt <- function(sources, context_layer) {
  template <- paste(
    readLines(
      system.file("prompts/system-prompt.md", package = "commons"),
      warn = FALSE
    ),
    collapse = "\n"
  )

  tables <- sources_tables_text(sources)

  always <- if (!is.null(context_layer) && length(context_layer$always)) {
    paste0(
      "\n# Context\n\nThe following context may be relevant:\n\n",
      paste(sprintf("- %s", context_layer$always), collapse = "\n")
    )
  } else {
    ""
  }

  template <- fill_token(template, "{{TABLES}}", tables)
  template <- fill_token(template, "{{DICTIONARY}}", dictionary_prompt_text(sources))
  fill_token(template, "{{ALWAYS}}", always)
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

# Avoid regular expression handling in prompt fragments supplied by users.
fill_token <- function(text, token, value) {
  gsub(token, value, text, fixed = TRUE)
}

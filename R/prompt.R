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
  fill_token(template, "{{ALWAYS}}", always)
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

commons_system_prompt <- function(data_source, context_layer) {
  template <- paste(
    readLines(
      system.file("prompts/system-prompt.md", package = "commons"),
      warn = FALSE
    ),
    collapse = "\n"
  )

  tables <- paste(sprintf("- %s", list_tables(data_source)), collapse = "\n")

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

# Avoid regular expression handling in prompt fragments supplied by users.
fill_token <- function(text, token, value) {
  gsub(token, value, text, fixed = TRUE)
}

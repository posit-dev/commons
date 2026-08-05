commons_system_prompt <- function(
  sources,
  system_prompt,
  definitions = NULL,
  measures = list(),
  calculations = list()
) {
  definitions <- definitions %||% definitions_registry(sources)
  template <- read_system_prompt(system_prompt)
  data <- system_prompt_data(sources, definitions, measures, calculations)
  render_system_prompt(template, data)
}

system_prompt_data <- function(sources, definitions, measures, calculations) {
  has_measures <- length(measures) > 0
  has_calculations <- length(calculations) > 0
  has_metrics <- registry_has_metrics(definitions)
  has_definitions <- nrow(registry_defs(definitions)) > 0
  dictionary_context <- dictionary_context_text(sources)
  glossary_context <- glossary_context_text(sources)
  diagnostics <- catalog_diagnostics_text(sources)

  list(
    date = as.character(Sys.Date()),
    has_measures = has_measures,
    has_calculations = has_calculations,
    has_metrics = has_metrics,
    has_definitions = has_definitions,
    has_governed_operations = has_measures || has_definitions ||
      has_calculations,
    has_search_pool = pool_searchable(measures, definitions, calculations),
    has_multiple_sources = length(sources) > 1,
    has_dictionary_context = nzchar(dictionary_context) ||
      nzchar(glossary_context),
    has_glossary_context = nzchar(glossary_context),
    has_catalog_diagnostics = nzchar(diagnostics),
    definitions_complete = !definitions_overflow(definitions),
    tables = tables_text(sources),
    dictionary_context = dictionary_context,
    glossary_context = glossary_context,
    catalog_diagnostics = diagnostics,
    definition_index = definition_index_text(definitions),
    definition_action = definition_action_text(definitions),
    definition_guidance = paste(
      "# Governed definitions",
      paste0(
        "Governed definitions are indexed here by table. Native semantic ",
        "metrics run through `call_metrics`. For data-dictionary expressions: ",
        "Write them as `{{name}}` tokens anywhere in `run_sql` SQL ",
        "(`{{table.name}}` when a name exists on several tables); each expands ",
        "to its governed SQL before the query runs. Expansion can't add an ",
        "alias, so write `SELECT {{name}} AS name`. Metric expressions are ",
        "already aggregates\u2014never wrap one in `SUM()` or another aggregate."
      ),
      sep = "\n\n"
    )
  )
}

catalog_diagnostics_text <- function(sources) {
  labels <- rlang::names2(sources)
  lines <- character()
  for (i in seq_along(sources)) {
    catalog <- sources[[i]]$provider$catalog %||% sources[[i]]$catalog
    if (!inherits(catalog, "commons_catalog")) {
      next
    }
    diagnostics <- Filter(
      function(diagnostic) diagnostic$severity %in% c("warning", "error"),
      catalog$diagnostics
    )
    if (length(diagnostics) == 0) {
      next
    }
    prefix <- if (length(sources) > 1) paste0(labels[[i]], ": ") else ""
    lines <- c(lines, vapply(
      diagnostics,
      function(diagnostic) paste0("- ", prefix, diagnostic$message),
      character(1)
    ))
  }
  paste(unique(lines), collapse = "\n")
}

definition_action_text <- function(definitions) {
  defs <- registry_defs(definitions)
  c(
    if (any(defs$execution == "data_dictionary")) {
      "- Apply a data-dictionary definition as a `{{name}}` token in `run_sql` SQL."
    },
    if (any(defs$execution != "data_dictionary")) {
      "- Run native semantic metrics with `call_metrics`; do not copy their SQL expressions into `run_sql`."
    }
  ) |>
    paste(collapse = "\n")
}

render_system_prompt <- function(
  template,
  data,
  call = rlang::caller_env()
) {
  envir <- list2env(data, parent = baseenv())
  out <- glue::glue(
    template,
    .open = "{[",
    .close = "]}",
    .envir = envir
  )
  rlang::check_string(out, arg = "rendered system prompt", call = call)
  out <- as.character(out)
  out <- gsub("(?s)<!--.*?-->", "", out, perl = TRUE)
  out <- gsub("\n[ \t]*\n(?:[ \t]*\n)+", "\n\n", out, perl = TRUE)
  trimws(out)
}

check_system_prompt <- function(system_prompt, call = rlang::caller_env()) {
  rlang::check_string(system_prompt, call = call)
  if (looks_like_prompt_path(system_prompt) && !file.exists(system_prompt)) {
    cli::cli_abort(
      "System-prompt file {.path {system_prompt}} does not exist.",
      call = call
    )
  }
  invisible(system_prompt)
}

read_system_prompt <- function(system_prompt) {
  if (!file.exists(system_prompt)) {
    return(system_prompt)
  }
  paste(
    readLines(system_prompt, warn = FALSE, encoding = "UTF-8"),
    collapse = "\n"
  )
}

looks_like_prompt_path <- function(system_prompt) {
  if (grepl("\n", system_prompt, fixed = TRUE)) {
    return(FALSE)
  }

  extension <- tolower(tools::file_ext(system_prompt))
  grepl("[/\\\\]", system_prompt) ||
    extension %in% c("md", "rmd", "txt", "prompt") ||
    (nzchar(extension) && !grepl("[[:space:]]", system_prompt))
}

dictionary_context_text <- function(sources) {
  blocks <- character()
  for (i in seq_along(sources)) {
    dictionary <- sources[[i]]$dictionary
    if (is.null(dictionary)) {
      next
    }
    content <- c(dictionary$description, dictionary$details)
    if (length(content) == 0) {
      next
    }
    label <- dictionary_prompt_label(sources, i)
    blocks <- c(
      blocks,
      paste(
        c(if (nzchar(label)) sprintf("## %s", label), content),
        collapse = "\n\n"
      )
    )
  }
  paste(blocks, collapse = "\n\n")
}

glossary_context_text <- function(sources) {
  blocks <- character()
  for (i in seq_along(sources)) {
    dictionary <- sources[[i]]$dictionary
    if (is.null(dictionary)) {
      next
    }
    ambient <- glossary_ambient(dictionary)
    if (length(ambient) == 0) {
      next
    }
    lines <- sprintf(
      "- %s: %s",
      ambient,
      vapply(dictionary$glossary[ambient], flatten_inline, character(1))
    )
    if (length(sources) > 1) {
      lines <- sprintf(
        "- %s \u2014 %s",
        dictionary_prompt_label(sources, i),
        substring(lines, 3)
      )
    }
    blocks <- c(blocks, paste(lines, collapse = "\n"))
  }
  paste(blocks, collapse = "\n\n")
}

dictionary_prompt_label <- function(sources, i) {
  if (length(sources) > 1) {
    return(rlang::names2(sources)[[i]])
  }
  sources[[i]]$dictionary$name %||% ""
}

tables_text <- function(sources) {
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
  paste(blocks, collapse = "\n\n")
}

table_bullets <- function(source) {
  if (catalog_provider_searchable(source)) {
    return("The selected catalog is large. Use `search_catalog` to find tables before calling `describe_table`.")
  }
  paste(sprintf("- %s", list_tables(source)), collapse = "\n")
}

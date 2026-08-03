commons_system_prompt <- function(
  sources,
  system_prompt,
  definitions = NULL,
  measures = list()
) {
  definitions <- definitions %||% definitions_registry(sources)
  template <- read_system_prompt(system_prompt)
  data <- system_prompt_data(sources, definitions, measures)
  render_system_prompt(template, data)
}

system_prompt_data <- function(sources, definitions, measures) {
  has_measures <- length(measures) > 0
  has_metrics <- registry_has_metrics(definitions)
  has_definitions <- nrow(registry_defs(definitions)) > 0
  dictionary_context <- dictionary_context_text(sources)
  glossary_context <- glossary_context_text(sources)

  list(
    date = as.character(Sys.Date()),
    has_measures = has_measures,
    has_metrics = has_metrics,
    has_definitions = has_definitions,
    has_governed_operations = has_measures || has_definitions,
    has_search_pool = pool_searchable(measures, definitions),
    has_multiple_sources = length(sources) > 1,
    has_dictionary_context = nzchar(dictionary_context) ||
      nzchar(glossary_context),
    has_glossary_context = nzchar(glossary_context),
    definitions_complete = !definitions_overflow(definitions),
    tables = tables_text(sources),
    dictionary_context = dictionary_context,
    glossary_context = glossary_context,
    definition_index = definition_index_text(definitions)
  )
}

render_system_prompt <- function(
  template,
  data,
  call = rlang::caller_env()
) {
  out <- ellmer::interpolate(template, !!!data, .envir = baseenv())
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
  paste(sprintf("- %s", list_tables(source)), collapse = "\n")
}

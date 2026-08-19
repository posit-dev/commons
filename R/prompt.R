commons_system_prompt <- function(
  sources,
  definitions = NULL,
  instructions = NULL,
  tools = list()
) {
  definitions <- definitions %||% definitions_registry(sources)
  instructions <- read_instructions(instructions)
  template <- read_system_prompt()
  data <- system_prompt_data(sources, definitions, instructions, tools)
  render_system_prompt(template, data)
}

system_prompt_data <- function(
  sources,
  definitions,
  instructions = NULL,
  tools = list()
) {
  dictionary_context <- dictionary_context_text(sources)
  glossary_context <- glossary_context_text(sources)
  tool_names <- available_tool_names(tools)

  list(
    date = as.character(Sys.Date()),
    has_multiple_sources = length(sources) > 1,
    has_catalog_search = any(vapply(sources, catalog_searchable, logical(1))),
    has_dictionary_context = nzchar(dictionary_context) ||
      nzchar(glossary_context),
    has_glossary_context = nzchar(glossary_context),
    definitions_complete = !definitions_overflow(definitions),
    tables = tables_text(sources),
    dictionary_context = dictionary_context,
    glossary_context = glossary_context,
    definition_index = definition_index_text(definitions),
    citation_trust_exception = citation_trust_exception(tool_names),
    citable_tool_outputs = citable_tool_output_text(tool_names),
    non_citable_tool_outputs = non_citable_tool_output_text(tool_names),
    has_instructions = nzchar(instructions %||% ""),
    instructions = instructions %||% ""
  )
}

render_system_prompt <- function(
  template,
  data,
  call = rlang::caller_env()
) {
  envir <- list2env(data, parent = baseenv())
  out <- glue::glue(template, .envir = envir)
  rlang::check_string(out, arg = "rendered system prompt", call = call)
  out <- as.character(out)
  out <- gsub("(?s)<!--.*?-->", "", out, perl = TRUE)
  out <- gsub("\n[ \t]*\n(?:[ \t]*\n)+", "\n\n", out, perl = TRUE)
  trimws(out)
}

check_instructions <- function(instructions, call = rlang::caller_env()) {
  rlang::check_string(instructions, allow_null = TRUE, call = call)
  if (is.null(instructions)) {
    return(invisible(instructions))
  }
  if (looks_like_instructions_path(instructions) && !file.exists(instructions)) {
    cli::cli_abort(
      "Instructions file {.path {instructions}} does not exist.",
      call = call
    )
  }
  invisible(instructions)
}

read_system_prompt <- function() {
  path <- system.file("prompts/system-prompt.md", package = "commons")
  paste(
    readLines(path, warn = FALSE, encoding = "UTF-8"),
    collapse = "\n"
  )
}

read_instructions <- function(instructions) {
  if (is.null(instructions) || !file.exists(instructions)) {
    return(instructions)
  }
  paste(
    readLines(instructions, warn = FALSE, encoding = "UTF-8"),
    collapse = "\n"
  )
}

looks_like_instructions_path <- function(instructions) {
  if (grepl("\n", instructions, fixed = TRUE)) {
    return(FALSE)
  }

  extension <- tolower(tools::file_ext(instructions))
  grepl("[/\\\\]", instructions) ||
    extension %in% c("md", "rmd", "txt", "prompt") ||
    (nzchar(extension) && !grepl("[[:space:]]", instructions))
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
  if (catalog_searchable(source)) {
    return(sprintf(
      "%d selected catalog objects. Use `search_catalog` to find tables before calling `describe_table`.",
      length(list_tables(source))
    ))
  }
  paste(sprintf("- %s", list_tables(source)), collapse = "\n")
}

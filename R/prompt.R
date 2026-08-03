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
  lines <- strsplit(template, "\n", fixed = TRUE)[[1]]
  output <- character()
  stack <- list()
  active <- TRUE

  for (i in seq_along(lines)) {
    line <- lines[[i]]
    condition <- prompt_if_directive(line)

    if (!is.null(condition)) {
      value <- prompt_condition(data, condition, i, call)
      stack[[length(stack) + 1]] <- list(
        parent_active = active,
        condition = value,
        has_else = FALSE
      )
      active <- active && value
      next
    }

    if (grepl("^\\s*<!--\\s*commons:else\\s*-->\\s*$", line, perl = TRUE)) {
      if (length(stack) == 0) {
        cli::cli_abort(
          "Unexpected {.code commons:else} on line {i}.",
          call = call
        )
      }
      frame <- stack[[length(stack)]]
      if (frame$has_else) {
        cli::cli_abort(
          "Duplicate {.code commons:else} on line {i}.",
          call = call
        )
      }
      frame$has_else <- TRUE
      stack[[length(stack)]] <- frame
      active <- frame$parent_active && !frame$condition
      next
    }

    if (grepl("^\\s*<!--\\s*commons:endif\\s*-->\\s*$", line, perl = TRUE)) {
      if (length(stack) == 0) {
        cli::cli_abort(
          "Unexpected {.code commons:endif} on line {i}.",
          call = call
        )
      }
      frame <- stack[[length(stack)]]
      stack[[length(stack)]] <- NULL
      active <- frame$parent_active
      next
    }

    if (grepl("<!--\\s*commons:", line, perl = TRUE)) {
      cli::cli_abort(
        "Malformed commons prompt directive on line {i}: {.code {trimws(line)}}.",
        call = call
      )
    }

    if (active) {
      output <- c(output, line)
    }
  }

  if (length(stack) > 0) {
    cli::cli_abort(
      "The system prompt has {length(stack)} unclosed conditional block{?s}.",
      call = call
    )
  }

  out <- paste(output, collapse = "\n")
  out <- gsub("(?s)<!--.*?-->", "", out, perl = TRUE)
  out <- interpolate_prompt_data(out, data, call)
  out <- gsub("\n[ \t]*\n(?:[ \t]*\n)+", "\n\n", out, perl = TRUE)
  trimws(out)
}

prompt_if_directive <- function(line) {
  match <- regexec(
    "^\\s*<!--\\s*commons:if\\s+([A-Za-z][A-Za-z0-9_]*)\\s*-->\\s*$",
    line,
    perl = TRUE
  )
  parts <- regmatches(line, match)[[1]]
  if (length(parts) == 0) {
    return(NULL)
  }
  parts[[2]]
}

prompt_condition <- function(data, name, line, call) {
  if (!name %in% names(data)) {
    cli::cli_abort(
      "Unknown system-prompt condition {.code {name}} on line {line}.",
      call = call
    )
  }
  value <- data[[name]]
  if (!is.logical(value) || length(value) != 1 || is.na(value)) {
    cli::cli_abort(
      "System-prompt condition {.code {name}} must be a single non-missing logical value.",
      call = call
    )
  }
  value
}

interpolate_prompt_data <- function(prompt, data, call) {
  pattern <- "\\{\\{\\s*data\\.([A-Za-z][A-Za-z0-9_]*)\\s*\\}\\}"
  matches <- regmatches(prompt, gregexpr(pattern, prompt, perl = TRUE))[[1]]
  if (length(matches) == 0) {
    return(prompt)
  }

  for (token in unique(matches)) {
    name <- sub(pattern, "\\1", token, perl = TRUE)
    if (!name %in% names(data)) {
      cli::cli_abort(
        "Unknown system-prompt interpolation value {.code data.{name}}.",
        call = call
      )
    }
    value <- data[[name]]
    if (length(value) != 1 || is.list(value) || is.na(value)) {
      cli::cli_abort(
        "System-prompt interpolation value {.code data.{name}} must be a single non-missing value.",
        call = call
      )
    }
    prompt <- replace_prompt_token(prompt, token, as.character(value))
  }
  prompt
}

replace_prompt_token <- function(prompt, token, value) {
  locations <- gregexpr(token, prompt, fixed = TRUE)[[1]]
  if (locations[[1]] == -1) {
    return(prompt)
  }
  width <- nchar(token)
  for (location in rev(locations)) {
    prompt <- paste0(
      substr(prompt, 1, location - 1),
      value,
      substr(prompt, location + width, nchar(prompt))
    )
  }
  prompt
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
  !grepl("\n", system_prompt, fixed = TRUE) &&
    (grepl("\\.(md|txt)$", system_prompt) ||
      (grepl("[/\\\\]", system_prompt) && dir.exists(dirname(system_prompt))))
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

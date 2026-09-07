commons_system_prompt <- function(
  sources,
  definitions = NULL,
  instructions = NULL,
  tools = list(),
  model = NULL
) {
  definitions <- definitions %||% definitions_registry(sources)
  instructions <- read_instructions(instructions)
  template <- read_system_prompt()
  data <- system_prompt_data(sources, definitions, instructions, tools, model)
  render_system_prompt(template, data)
}

system_prompt_data <- function(
  sources,
  definitions,
  instructions = NULL,
  tools = list(),
  model = NULL
) {
  dictionary_context <- dictionary_context_text(sources)
  glossary_context <- glossary_context_text(sources)
  definition_index <- definition_index_text(definitions)
  definitions_complete <- !definitions_overflow(definitions)
  tool_names <- available_tool_names(tools)

  c(
    list(
      date = as.character(Sys.Date()),
      is_claude_5 = is_claude_5_model(model),
      has_multiple_sources = length(sources) > 1,
      has_catalog_search = any(vapply(sources, catalog_searchable, logical(1))),
      has_dictionary_context = nzchar(dictionary_context) ||
        nzchar(glossary_context),
      has_glossary_context = nzchar(glossary_context),
      definitions_complete = definitions_complete,
      # The template branches on names rather than expressions, so the two
      # conditions that combine the index with its completeness are resolved
      # here.
      has_definitions = nzchar(definition_index) || !definitions_complete,
      has_complete_definitions = nzchar(definition_index) && definitions_complete,
      tables = tables_text(sources),
      dictionary_context = dictionary_context,
      glossary_context = glossary_context,
      definition_index = definition_index,
      citation_trust_exception = citation_trust_exception(tool_names)
    ),
    tool_availability(tool_names),
    list(
      has_instructions = nzchar(instructions %||% ""),
      instructions = instructions %||% ""
    )
  )
}

is_claude_5_model <- function(model) {
  if (!rlang::is_string(model)) {
    return(FALSE)
  }
  grepl(
    "(^|[./:_-])claude-[^-]+-5($|[./:@_-])",
    tolower(model),
    perl = TRUE
  )
}

render_system_prompt <- function(
  template,
  data,
  call = rlang::caller_env()
) {
  out <- render_template(template, data, call = call)
  out <- gsub("(?s)<!--.*?-->", "", out, perl = TRUE)
  out <- gsub("\n[ \t]*\n(?:[ \t]*\n)+", "\n\n", out, perl = TRUE)
  trimws(out)
}

# The template is shared with the Python package, so it is Jinja2 rather than
# glue. This renders the subset the template uses: `{{ name }}` substitution,
# `{% if name %}` / `{% if not name %}` / `{% else %}` / `{% endif %}` on plain
# names, and `{% raw %}` for literal braces. Python renders the same file with
# jinja2 configured for the same whitespace handling; tests/shared/
# prompt-render.json pins the two to the same output.
#
# Substituted values are inserted literally and never rendered again, which is
# what lets governed-definition tokens and app-authored instructions contain
# template syntax of their own.
template_token <- "(?s)\\{\\{\\s*[A-Za-z_][A-Za-z0-9_]*\\s*\\}\\}|\\{%.*?%\\}"

render_template <- function(template, data, call = rlang::caller_env()) {
  # Jinja2's lexer normalizes line endings, so a template read from a CRLF
  # checkout renders the same in both packages.
  template <- gsub("\r\n", "\n", template, fixed = TRUE)
  check_template_syntax(template, call = call)
  check_template_data(template, data, call = call)
  found <- gregexpr(template_token, template, perl = TRUE)[[1]]
  if (found[[1]] == -1L) {
    return(template)
  }
  starts <- as.integer(found)
  ends <- starts + attr(found, "match.length") - 1L

  out <- character()
  frames <- list()
  raw <- FALSE
  pos <- 1L
  keeping <- function() all(vapply(frames, function(f) f$keep, logical(1)))

  for (i in seq_along(starts)) {
    literal <- substr(template, pos, starts[[i]] - 1L)
    token <- substr(template, starts[[i]], ends[[i]])
    pos <- ends[[i]] + 1L

    if (raw) {
      # Only `{% endraw %}` closes a raw region; everything else is content.
      if (identical(template_tag(token), "endraw")) {
        raw <- FALSE
        # `{% endraw %}` is a block tag, so it takes its line with it too.
        literal <- sub("(^|\n)[ \t]+$", "\\1", literal)
        if (substr(template, pos, pos) == "\n") {
          pos <- pos + 1L
        }
      } else {
        literal <- paste0(literal, token)
      }
      if (keeping()) {
        out <- c(out, literal)
      }
      next
    }

    if (startsWith(token, "{{")) {
      if (keeping()) {
        name <- gsub("^\\{\\{\\s*|\\s*\\}\\}$", "", token)
        out <- c(out, literal, template_string(name, data, call))
      }
      next
    }

    # Jinja2's lstrip_blocks and trim_blocks: a block tag alone on a line takes
    # the whole line with it.
    literal <- sub("(^|\n)[ \t]+$", "\\1", literal)
    if (substr(template, pos, pos) == "\n") {
      pos <- pos + 1L
    }
    if (keeping()) {
      out <- c(out, literal)
    }

    tag <- template_tag(token)
    if (identical(tag, "raw")) {
      raw <- TRUE
    } else if (grepl("^if ", tag)) {
      condition <- sub("^if\\s+", "", tag)
      negated <- grepl("^not\\s+", condition)
      name <- sub("^not\\s+", "", condition)
      keep <- template_flag(name, data, call)
      if (negated) {
        keep <- !keep
      }
      frames <- c(frames, list(list(keep = keep, taken = keep, elsed = FALSE)))
    } else if (identical(tag, "else")) {
      frame <- template_frame(frames, token, call)
      if (frame$elsed) {
        cli::cli_abort(
          "Prompt template has a second {.code {{% else %}}} in one
           {.code {{% if %}}}.",
          call = call
        )
      }
      frames[[length(frames)]] <- list(
        keep = !frame$taken,
        taken = TRUE,
        elsed = TRUE
      )
    } else if (identical(tag, "endif")) {
      template_frame(frames, token, call)
      frames[[length(frames)]] <- NULL
    } else {
      cli::cli_abort(
        "Unsupported prompt template tag {.code {token}}.",
        call = call
      )
    }
  }

  if (length(frames) > 0) {
    cli::cli_abort("Prompt template has an unclosed {.code {{% if %}}}.", call = call)
  }
  if (raw) {
    cli::cli_abort("Prompt template has an unclosed {.code {{% raw %}}}.", call = call)
  }
  paste0(paste(out, collapse = ""), substring(template, pos))
}

# Jinja2 is much larger than the subset both packages implement, so a template
# that reaches beyond it is rejected here rather than rendering in Python and
# failing in R.
TEMPLATE_RAW <- "(?s)\\{%\\s*raw\\s*%\\}.*?\\{%\\s*endraw\\s*%\\}"
TEMPLATE_CLOSED <- "(?s)\\{\\{.*?\\}\\}|\\{%.*?%\\}|\\{#.*?#\\}"
SUPPORTED_TAG <- "^(if\\s+(not\\s+)?[A-Za-z_][A-Za-z0-9_]*|else|endif|raw|endraw)$"
SUPPORTED_VALUE <- "^\\{\\{\\s*[A-Za-z_][A-Za-z0-9_]*\\s*\\}\\}$"

check_template_syntax <- function(template, call = rlang::caller_env()) {
  outside_raw <- gsub(TEMPLATE_RAW, "", template, perl = TRUE)

  # An opening delimiter that is never closed matches none of the token
  # patterns, so without this it would pass through as prompt text while
  # Jinja2 rejects the same template.
  loose <- gsub(TEMPLATE_CLOSED, "", outside_raw, perl = TRUE)
  if (grepl("\\{\\{|\\{%|\\{#", loose)) {
    cli::cli_abort(
      "Prompt template has an opening delimiter that is never closed.",
      call = call
    )
  }

  tags <- template_matches(outside_raw, "(?s)\\{%.*?%\\}")
  unsupported <- tags[!grepl(SUPPORTED_TAG, template_tag(tags), perl = TRUE)]

  values <- template_matches(outside_raw, "(?s)\\{\\{.*?\\}\\}")
  unsupported <- c(
    unsupported,
    values[!grepl(SUPPORTED_VALUE, values, perl = TRUE)],
    template_matches(outside_raw, "(?s)\\{#.*?#\\}")
  )

  if (length(unsupported) > 0) {
    cli::cli_abort(
      c(
        "Unsupported prompt template syntax {.code {unsupported[[1]]}}.",
        i = "Templates are shared with the Python package, which renders the
             same subset: {.code {{{{ name }}}}}, {.code {{% if name %}}},
             {.code {{% if not name %}}}, {.code {{% else %}}},
             {.code {{% endif %}}}, and {.code {{% raw %}}}."
      ),
      call = call
    )
  }
  invisible(template)
}

# Every name the template uses is checked before rendering, not when its branch
# happens to be taken. A value missing from a section that is switched off is
# still a defect, and checking lazily would hide it in one package until some
# later prompt change switched the section on.
CONDITION_NAME <- "\\{%\\s*if\\s+(?:not\\s+)?([A-Za-z_][A-Za-z0-9_]*)\\s*%\\}"

check_template_data <- function(template, data, call = rlang::caller_env()) {
  outside_raw <- gsub(TEMPLATE_RAW, "", template, perl = TRUE)

  conditions <- template_matches(outside_raw, CONDITION_NAME)
  for (name in sub(CONDITION_NAME, "\\1", conditions, perl = TRUE)) {
    template_flag(name, data, call)
  }

  values <- template_matches(outside_raw, "(?s)\\{\\{.*?\\}\\}")
  for (name in gsub("^\\{\\{\\s*|\\s*\\}\\}$", "", values)) {
    template_string(name, data, call)
  }
  invisible(template)
}

template_matches <- function(text, pattern) {
  regmatches(text, gregexpr(pattern, text, perl = TRUE))[[1]]
}

# Jinja2 lets a tag span lines, so the whitespace inside one is normalized
# before the tag is matched against the supported set.
template_tag <- function(token) {
  gsub("\\s+", " ", trimws(gsub("^\\{%\\s*|\\s*%\\}$", "", token)))
}

template_frame <- function(frames, token, call) {
  if (length(frames) == 0) {
    cli::cli_abort(
      "Prompt template has {.code {token}} outside an {.code {{% if %}}}.",
      call = call
    )
  }
  frames[[length(frames)]]
}

template_string <- function(name, data, call) {
  value <- template_value(name, data, call)
  if (!rlang::is_string(value)) {
    cli::cli_abort(
      "Prompt template value {.field {name}} must be a single string.",
      call = call
    )
  }
  value
}

# Conditions are names rather than expressions, and the name must already hold a
# flag. Anything compound is computed in system_prompt_data() instead, so that
# both languages branch on the same value rather than on their own reading of an
# expression.
template_flag <- function(name, data, call) {
  value <- template_value(name, data, call)
  if (!rlang::is_bool(value)) {
    cli::cli_abort(
      "Prompt template condition {.field {name}} must be TRUE or FALSE.",
      call = call
    )
  }
  value
}

template_value <- function(name, data, call) {
  if (!name %in% names(data)) {
    cli::cli_abort(
      "Prompt template refers to {.field {name}}, which has no value.",
      call = call
    )
  }
  data[[name]]
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
  read_prompt("system-prompt.md")
}

# prompts/ at the repository root is the source; inst/prompts/ holds the copy
# scripts/sync-shared.sh generates.
read_prompt <- function(name) {
  path <- system.file("prompts", name, package = "commons")
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
    source_state <- data_source_state(sources[[i]])
    dictionary <- source_state$dictionary
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
    source_state <- data_source_state(sources[[i]])
    dictionary <- source_state$dictionary
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
  data_source_state(sources[[i]])$dictionary$name %||% ""
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
    source_state <- data_source_state(source)
    return(sprintf(
      "%d selected catalog objects. Use `search_catalog` to find objects before calling `describe_table`.",
      length(source_state$manifest$objects)
    ))
  }
  paste(sprintf("- %s", list_tables(source)), collapse = "\n")
}

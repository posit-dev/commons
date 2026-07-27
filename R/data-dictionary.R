# Read a data dictionary from disk into the normalized representation the
# rest of the package works from. Only the data-dict.yaml format exists
# today; when other formats arrive (a dbt manifest, harvested catalog
# metadata), this is where the format is inferred and dispatched.
data_dictionary <- function(path) {
  rlang::check_installed("yaml")
  rlang::check_string(path, allow_empty = FALSE)
  new_data_dictionary(yaml::read_yaml(path))
}

as_data_dictionary <- function(x, call = rlang::caller_env()) {
  if (is.null(x) || inherits(x, "commons_data_dictionary")) {
    return(x)
  }
  if (is.character(x) && length(x) == 1) {
    return(data_dictionary(x))
  }
  cli::cli_abort(
    "{.arg dictionary} must be a path to a data-dict.yaml file.",
    call = call
  )
}

new_data_dictionary <- function(raw, call = rlang::caller_env()) {
  raw <- raw %||% list()
  structure(
    list(
      name = prose_field(raw$name),
      description = prose_field(raw$description),
      details = prose_field(raw$details),
      tables = normalize_dictionary_tables(raw$tables, call = call),
      relationships = normalize_dictionary_relationships(raw$relationships),
      glossary = normalize_dictionary_glossary(raw$glossary)
    ),
    class = "commons_data_dictionary"
  )
}

normalize_dictionary_tables <- function(tables, call = rlang::caller_env()) {
  tables <- key_by_name(tables, "table", call = call)
  lapply(tables, function(table) {
    table <- as.list(table)
    table$columns <- key_by_name(table$columns, "column", call = call)
    table
  })
}

# data-dict.yaml lists tables and columns as sequences with a `name` field;
# key entries by that name for lookup. A pre-keyed map is accepted as-is.
key_by_name <- function(entries, what, call = rlang::caller_env()) {
  if (length(entries) == 0) {
    return(list())
  }
  if (all(nzchar(rlang::names2(entries)))) {
    return(entries)
  }

  nms <- vapply(
    entries,
    function(entry) {
      name <- if (is.list(entry)) entry[["name"]]
      if (!is.character(name) || length(name) != 1 || !nzchar(name)) {
        cli::cli_abort(
          "Each {what} in a data dictionary needs a {.field name}.",
          call = call
        )
      }
      name
    },
    character(1)
  )
  entries <- lapply(entries, function(entry) {
    entry[["name"]] <- NULL
    entry
  })
  names(entries) <- nms
  entries
}

normalize_dictionary_relationships <- function(relationships) {
  if (length(relationships) == 0) {
    return(list())
  }
  relationships[vapply(relationships, is.list, logical(1))]
}

normalize_dictionary_glossary <- function(glossary) {
  glossary <- glossary[nzchar(rlang::names2(glossary))]
  lapply(glossary, prose_field)
}

prose_field <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  paste(as.character(x), collapse = "\n")
}

# ---- first-touch rendering -------------------------------------------------

# The full entry for one table, delivered when a SQL query touches a table
# the conversation hasn't seen. describe_table composes its own body from
# dictionary_entry_parts() so it can merge the live schema and keep sample
# rows.
dictionary_entry_text <- function(dictionary, table) {
  entry <- dictionary$tables[[table]]
  if (is.null(entry)) {
    return(NULL)
  }
  columns <- dictionary_columns_text(entry$columns)
  if (!is.null(columns)) {
    columns <- paste0("Documented columns:\n\n", columns)
  }
  parts <- c(
    sprintf("Dictionary entry for `%s`:", table),
    dictionary_entry_parts(dictionary, table, columns)
  )
  paste(parts, collapse = "\n\n")
}

dictionary_entry_parts <- function(dictionary, table, columns_text) {
  entry <- dictionary$tables[[table]]
  parts <- c(
    entry$description,
    entry$details,
    columns_text,
    dictionary_relationships_text(dictionary, table)
  )
  c(parts, dictionary_terms_text(dictionary, paste(parts, collapse = "\n")))
}

# One bullet per column. With a live schema (from describe_table), all live
# columns appear, documented ones annotated and undocumented ones keeping
# their inferred type; documented columns missing from the table are flagged.
# Without one (the run_sql path), only documented columns appear.
dictionary_columns_text <- function(columns, live = NULL) {
  if (is.null(live)) {
    if (length(columns) == 0) {
      return(NULL)
    }
    lines <- vapply(
      names(columns),
      function(nm) dictionary_column_line(nm, columns[[nm]]),
      character(1)
    )
    return(paste(lines, collapse = "\n"))
  }

  lines <- vapply(
    seq_len(nrow(live)),
    function(i) {
      dictionary_column_line(
        live$column[[i]],
        columns[[live$column[[i]]]],
        live_type = live$type[[i]]
      )
    },
    character(1)
  )
  out <- paste(lines, collapse = "\n")

  missing <- setdiff(names(columns), live$column)
  if (length(missing)) {
    out <- paste0(
      out,
      sprintf(
        "\n\nDocumented in the dictionary but not present in the table: %s.",
        paste(missing, collapse = ", ")
      )
    )
  }
  out
}

dictionary_column_line <- function(name, spec, live_type = NULL) {
  spec <- spec %||% list()
  qualifier <- paste(
    c(spec$type %||% live_type, spec$units, unlist(spec$constraints)),
    collapse = ", "
  )
  facts <- c(
    spec$description,
    dictionary_values_fact(spec$values),
    dictionary_range_fact(spec$range),
    dictionary_examples_fact(spec$examples),
    spec$details
  )
  detail <- flatten_inline(paste(facts, collapse = " "))

  line <- sprintf("- %s", name)
  if (nzchar(qualifier)) {
    line <- sprintf("%s (%s)", line, qualifier)
  }
  if (nzchar(detail)) {
    line <- sprintf("%s: %s", line, detail)
  }
  line
}

# `values` can be a sequence ([M, F]) or a map of value to meaning
# ({M: Male}).
dictionary_values_fact <- function(values) {
  if (is.null(values)) {
    return(NULL)
  }
  values <- unlist(values)
  labels <- rlang::names2(values)
  rendered <- ifelse(
    nzchar(labels),
    sprintf("%s (%s)", labels, as.character(values)),
    as.character(values)
  )
  sprintf("Values: %s.", paste(rendered, collapse = ", "))
}

dictionary_range_fact <- function(range) {
  if (length(range) < 2) {
    return(NULL)
  }
  sprintf("Range: %s to %s.", as.character(range[[1]]), as.character(range[[2]]))
}

dictionary_examples_fact <- function(examples) {
  if (is.null(examples)) {
    return(NULL)
  }
  sprintf("Examples: %s.", paste(as.character(unlist(examples)), collapse = ", "))
}

dictionary_relationships_text <- function(dictionary, table) {
  relationships <- dictionary$relationships
  mentions <- vapply(
    relationships,
    function(rel) {
      text <- paste(c(rel$join, rel$description), collapse = " ")
      grepl(word_pattern(table), text, ignore.case = TRUE)
    },
    logical(1)
  )
  if (!any(mentions)) {
    return(NULL)
  }

  lines <- vapply(
    relationships[mentions],
    function(rel) {
      head <- paste(
        c(rel$join, if (!is.null(rel$cardinality)) sprintf("(%s)", rel$cardinality)),
        collapse = " "
      )
      desc <- flatten_inline(rel$description %||% "")
      if (!nzchar(head)) {
        return(paste0("- ", desc))
      }
      if (nzchar(desc)) {
        return(paste0("- ", head, ": ", desc))
      }
      paste0("- ", head)
    },
    character(1)
  )
  paste0("Relationships:\n\n", paste(lines, collapse = "\n"))
}

# Definitions of glossary terms the entry references but the system prompt
# doesn't already carry (i.e. terms past the ambient cap).
dictionary_terms_text <- function(dictionary, text) {
  glossary <- dictionary$glossary
  candidates <- setdiff(names(glossary), glossary_ambient(dictionary))
  hits <- candidates[vapply(
    candidates,
    function(term) grepl(word_pattern(term), text, ignore.case = TRUE),
    logical(1)
  )]
  if (length(hits) == 0) {
    return(NULL)
  }
  lines <- sprintf("- %s: %s", hits, flatten_inline(unlist(glossary[hits])))
  paste0("Definitions:\n\n", paste(lines, collapse = "\n"))
}

# Glossary entries are ambient in the system prompt up to a size cap, in
# order of appearance; entries past it are co-resolved at first touch and
# searchable via the context layer.
glossary_ambient <- function(dictionary, cap_chars = 4000) {
  glossary <- dictionary$glossary
  if (length(glossary) == 0) {
    return(character(0))
  }
  sizes <- cumsum(nchar(names(glossary)) + nchar(unlist(glossary)))
  names(glossary)[sizes <= cap_chars]
}

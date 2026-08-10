# Governed definitions: named SQL expressions authored in a data dictionary's
# per-table `definitions` field, anticipating the envelope sketched in
# tidyverse/data-dict#134. The model writes them as {{name}} tokens in run_sql
# SQL; commons expands each token to its trusted expression before the query
# runs. Boolean definitions act as filters, aggregates as metrics, and
# everything else as dimensions.

normalize_dictionary_definitions <- function(
  definitions,
  table,
  columns,
  call = rlang::caller_env()
) {
  if (length(definitions) == 0) {
    return(list())
  }
  definitions <- key_by_name(definitions, "definition", call = call)

  for (name in names(definitions)) {
    if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", name)) {
      cli::cli_abort(
        c(
          "Definition names must be identifiers (letters, digits, and
           underscores); {.val {name}} on table {.val {table}} is not.",
          i = "Names become tokens like {.code {{{{{name}}}}}} in SQL and
           bare references in sibling expressions."
        ),
        call = call
      )
    }
    def <- as.list(definitions[[name]])
    for (field in c("expr", "type")) {
      value <- def[[field]]
      if (!rlang::is_string(value) || !nzchar(trimws(value))) {
        cli::cli_abort(
          "Definition {.val {name}} on table {.val {table}} is missing
           {.field {field}}.",
          call = call
        )
      }
    }
    def$expr <- trimws(def$expr)
    def$label <- prose_field(def$label)
    def$description <- prose_field(def$description)
    def$details <- prose_field(def$details)
    definitions[[name]] <- def
  }

  # A definition shadowing a column would silently change what sibling
  # references to that name mean.
  shadowed <- intersect(names(definitions), columns)
  if (length(shadowed)) {
    cli::cli_abort(
      "Definitions on table {.val {table}} must not share a name with its
       documented columns: {.val {shadowed}}.",
      call = call
    )
  }

  definitions <- resolve_definition_references(definitions, table, call = call)
  for (name in names(definitions)) {
    definitions[[name]]$role <- definition_role(
      definitions[[name]],
      name,
      table,
      call = call
    )
  }
  definitions
}

definition_role <- function(def, name, table, call = rlang::caller_env()) {
  aggregate <- grepl(
    "\\b(sum|count|avg|min|max)\\s*\\(",
    strip_sql_literals(def$expanded),
    ignore.case = TRUE
  )
  if (definition_base_type(def$type) != "boolean") {
    return(if (aggregate) "metric" else "dimension")
  }
  if (aggregate) {
    cli::cli_abort(
      c(
        "Boolean definition {.val {name}} on table {.val {table}} can't
         filter rows.",
        i = "Its expression aggregates over rows, so it has no per-row
         value. Restate it per row, or declare a non-boolean type."
      ),
      call = call
    )
  }
  "filter"
}

# A bare name in an expr that matches a sibling definition on the same table
# refers to it (per the #134 spec, e.g. `SUM(total) FILTER (WHERE realized)`).
# Store the fully-resolved SQL as `expanded` so every consumer splices it in
# one step.
resolve_definition_references <- function(
  definitions,
  table,
  call = rlang::caller_env()
) {
  references <- lapply(
    definitions,
    sibling_references,
    siblings = names(definitions)
  )

  expanded <- list()
  pending <- names(definitions)
  while (length(pending)) {
    ready <- pending[vapply(
      pending,
      function(name) !any(references[[name]] %in% pending),
      logical(1)
    )]
    if (length(ready) == 0) {
      cli::cli_abort(
        "Definitions on table {.val {table}} reference each other in a
         cycle: {.val {pending}}.",
        call = call
      )
    }
    for (name in ready) {
      expr <- definitions[[name]]$expr
      for (ref in references[[name]]) {
        expr <- gsub_outside_literals(
          expr,
          word_pattern(ref),
          sprintf("(%s)", expanded[[ref]])
        )
      }
      expanded[[name]] <- expr
      definitions[[name]]$expanded <- expr
    }
    pending <- setdiff(pending, ready)
  }
  definitions
}

sibling_references <- function(def, siblings) {
  code <- strip_sql_literals(def$expr)
  hits <- vapply(
    siblings,
    function(sibling) grepl(word_pattern(sibling), code),
    logical(1)
  )
  siblings[hits]
}

# Substitute outside single-quoted SQL string literals, so a definition
# named like a word inside a literal ('deduplicated') is left alone.
gsub_outside_literals <- function(x, pattern, replacement) {
  # gsub replacements treat backslashes and backreferences specially; the
  # substituted text is literal SQL.
  replacement <- gsub("\\", "\\\\", replacement, fixed = TRUE)
  literals <- gregexpr(sql_literal_pattern, x, perl = TRUE)
  code <- regmatches(x, literals, invert = TRUE)[[1]]
  regmatches(x, literals, invert = TRUE) <-
    list(gsub(pattern, replacement, code))
  x
}

strip_sql_literals <- function(x) {
  gsub(sql_literal_pattern, "''", x, perl = TRUE)
}

sql_literal_pattern <- "'(?:[^']|'')*'"

# Every source's definitions in one data frame.
definitions_registry <- function(sources, call = rlang::caller_env()) {
  rows <- list(no_definitions)
  labels <- rlang::names2(sources)
  for (i in seq_along(sources)) {
    source <- sources[[i]]
    for (table in names(source$dictionary$tables)) {
      definitions <- source$dictionary$tables[[table]]$definitions
      if (length(definitions) == 0) {
        next
      }
      if (!table %in% source$tables) {
        cli::cli_abort(
          "The data dictionary declares definitions on table {.val {table}},
           which the data source does not expose.",
          call = call
        )
      }
      rows[[length(rows) + 1]] <- definition_rows(
        definitions,
        table,
        labels[[i]]
      )
    }
  }
  list(defs = do.call(rbind, rows))
}

definition_fields <- c(
  "type",
  "role",
  "label",
  "description",
  "details",
  "expr",
  "expanded"
)

no_definitions <- data.frame(
  c(
    list(name = character(), table = character(), source = character()),
    rlang::rep_named(definition_fields, list(character()))
  )
)

definition_rows <- function(definitions, table, source) {
  out <- data.frame(
    name = names(definitions),
    table = table,
    source = source
  )
  for (field in definition_fields) {
    out[[field]] <- vapply(
      definitions,
      function(def) def[[field]] %||% NA_character_,
      character(1)
    )
  }
  out
}

registry_defs <- function(registry, source = NULL) {
  defs <- registry$defs
  if (is.null(source)) {
    return(defs)
  }
  defs[defs$source == source, ]
}

definition_base_type <- function(type) {
  tolower(sub("\\(.*$", "", trimws(type)))
}

definition_token_pattern <-
  "\\{\\{\\s*([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)\\s*\\}\\}"

# The expansion step of run_sql, before check_query() so the denylist sees
# the SQL that will actually execute.
expand_for_run_sql <- function(registry, sources, source_name, sql) {
  if (is.null(registry) || nrow(registry$defs) == 0) {
    return(list(sql = sql, applied = NULL))
  }
  label <- source_name %||% rlang::names2(sources)[[1]]
  expand_definitions(sql, registry_defs(registry, label))
}

expand_definitions <- function(sql, defs, call = rlang::caller_env()) {
  matches <- regmatches(
    sql,
    gregexpr(definition_token_pattern, sql, perl = TRUE)
  )[[1]]
  tokens <- unique(gsub("\\{\\{\\s*|\\s*\\}\\}", "", matches))

  applied <- NULL
  for (token in tokens) {
    def <- resolve_definition_token(token, sql, defs, call = call)
    # gsub replacement treats backslashes specially; the expansion is
    # literal SQL.
    replacement <- gsub(
      "\\",
      "\\\\",
      sprintf("(%s)", def$expanded),
      fixed = TRUE
    )
    sql <- gsub(
      sprintf("\\{\\{\\s*%s\\s*\\}\\}", escape_regex(token)),
      replacement,
      sql
    )
    applied <- rbind(applied, def)
  }
  list(sql = sql, applied = applied)
}

# A bare token scopes to the definitions whose table appears in the query
# text (the word-match heuristic dictionary_sql_entries() also uses), so
# same-named definitions on different tables coexist. Failures are tool
# errors the model can recover from in-conversation.
resolve_definition_token <- function(
  token,
  sql,
  defs,
  call = rlang::caller_env()
) {
  if (grepl(".", token, fixed = TRUE)) {
    parts <- strsplit(token, ".", fixed = TRUE)[[1]]
    name <- utils::tail(parts, 1L)
    table <- paste(utils::head(parts, -1L), collapse = ".")
    hits <- defs[defs$table == table & defs$name == name, ]
    if (nrow(hits) == 0) {
      abort_unknown_token(token, defs, call = call)
    }
    return(hits[1, ])
  }

  named <- defs[defs$name == token, ]
  if (nrow(named) == 0) {
    abort_unknown_token(token, defs, call = call)
  }

  in_scope <- named[
    vapply(
      named$table,
      function(table) grepl(word_pattern(table), sql, ignore.case = TRUE),
      logical(1)
    ),
  ]
  if (nrow(in_scope) == 1) {
    return(in_scope[1, ])
  }
  if (nrow(in_scope) == 0) {
    cli::cli_abort(
      "{.code {{{{{token}}}}}} is defined on table{?s} {.val {named$table}},
       which {?does/do} not appear in this query.",
      call = call
    )
  }
  qualified <- sprintf("{{%s.%s}}", in_scope$table, token)
  cli::cli_abort(
    c(
      "{.code {{{{{token}}}}}} is ambiguous here: it is defined on several
       tables in this query.",
      i = "Qualify the token: {.or {.code {qualified}}}."
    ),
    call = call
  )
}

abort_unknown_token <- function(token, defs, call) {
  available <- sprintf("{{%s}} (%s)", defs$name, defs$table)
  detail <- if (nrow(defs) == 0) {
    "This source has no governed definitions."
  } else {
    "Available definitions: {.code {available}}."
  }
  cli::cli_abort(
    c("No governed definition matches {.code {{{{{token}}}}}}.", i = detail),
    call = call
  )
}

definition_index_text <- function(registry, cap_chars = 4000) {
  index <- definition_index_lines(registry)
  if (length(index) == 0) {
    return("")
  }
  fits <- cumsum(nchar(index)) <= cap_chars
  paste(index[fits], collapse = "\n")
}

definitions_overflow <- function(registry, cap_chars = 4000) {
  !all(cumsum(nchar(definition_index_lines(registry))) <= cap_chars)
}

definition_index_lines <- function(registry) {
  defs <- registry_defs(registry)
  if (nrow(defs) == 0) {
    return(character())
  }

  scope <- defs$table
  if (length(unique(defs$source)) > 1) {
    scope <- paste(defs$source, defs$table, sep = ".")
  }
  role <- defs$role
  label <- flatten_inline(ifelse(is.na(defs$label), "", defs$label))
  item <- ifelse(
    nzchar(label),
    sprintf("`{{%s}}` (%s)", defs$name, label),
    sprintf("`{{%s}}`", defs$name)
  )

  groups <- c(
    filter = "filters",
    dimension = "dimensions",
    metric = "metrics"
  )
  vapply(
    unique(scope),
    function(one) {
      parts <- vapply(
        intersect(names(groups), role[scope == one]),
        function(r) {
          sprintf(
            "%s %s",
            groups[[r]],
            paste(item[scope == one & role == r], collapse = ", ")
          )
        },
        character(1)
      )
      sprintf("- %s: %s", one, paste(parts, collapse = "; "))
    },
    character(1)
  )
}

# A table's first-touch entry carries full expansions, so the model sees
# exactly what each token stands for without a search.
definitions_entry_text <- function(definitions) {
  if (length(definitions) == 0) {
    return(NULL)
  }
  paste0(
    "Governed definitions (write as `{{name}}` tokens in SQL):\n\n",
    paste(
      sprintf(
        "- `{{%s}}` %s",
        names(definitions),
        definition_gist(definitions)
      ),
      collapse = "\n"
    )
  )
}

# Indexed with the rest of the dictionary prose, so definitions are
# retrievable by search and citable.
definition_context_chunks <- function(dictionary) {
  unlist(lapply(names(dictionary$tables), function(table) {
    definitions <- dictionary$tables[[table]]$definitions
    sprintf(
      "Governed definition `{{%s}}` on table `%s` %s",
      names(definitions),
      table,
      definition_gist(definitions)
    )
  }))
}

definition_gist <- function(definitions) {
  vapply(
    definitions,
    function(def) {
      detail <- prose_detail(def$description, def$details)
      paste0(
        sprintf("(%s)", def$type),
        if (nzchar(detail)) paste0(": ", detail),
        sprintf(" Expands to `(%s)`.", flatten_inline(def$expanded))
      )
    },
    character(1)
  )
}

# Appended to the run_sql result so definition usage is auditable from the
# transcript.
applied_definitions_text <- function(applied) {
  if (NROW(applied) == 0) {
    return(NULL)
  }
  lines <- sprintf(
    "- {{%s}} (%s) expanded to `(%s)`",
    applied$name,
    applied$table,
    flatten_inline(applied$expanded)
  )
  paste0("Applied governed definitions:\n\n", paste(lines, collapse = "\n"))
}

# Fields are absent as NULL in dictionary lists and NA in registry rows.
prose_detail <- function(description, details) {
  fields <- c(description, details)
  flatten_inline(paste(fields[!is.na(fields)], collapse = " "))
}

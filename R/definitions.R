definition_export_dictionary <- function(tables, call = rlang::caller_env()) {
  tables <- tables[vapply(
    tables,
    function(table) length(table$definitions) > 0L,
    logical(1)
  )]
  input <- lapply(names(tables), function(name) {
    table <- tables[[name]]
    table$name <- name
    table$columns <- definition_named_sequence(table$columns)
    table$definitions <- definition_named_sequence(table$definitions)
    table
  })
  definition_export_spec(list(tables = unname(input)), call = call)
}

definition_named_sequence <- function(entries) {
  unname(Map(
    function(entry, name) {
      entry <- as.list(entry)
      entry$name <- name
      entry[c("name", setdiff(names(entry), "name"))]
    },
    entries,
    names(entries)
  ))
}

dictionary_attach_definition_export <- function(tables, export) {
  for (table in export$tables) {
    definitions <- table$definitions
    names(definitions) <- vapply(definitions, `[[`, character(1), "name")
    tables[[table$name]]$definitions <- definitions
  }
  tables
}

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

definition_scalar_fields <- c(
  "type",
  "kind",
  "label",
  "description",
  "details",
  "todo",
  "expression",
  "target",
  "sql"
)

definition_list_fields <- c(
  "columns",
  "definitions",
  "translations",
  "notes"
)

no_definitions <- data.frame(
  c(
    list(name = character(), table = character(), source = character()),
    rlang::rep_named(definition_scalar_fields, list(character())),
    list(mixed_grain = logical())
  )
)
for (field in definition_list_fields) {
  no_definitions[[field]] <- I(list())
}

definition_rows <- function(definitions, table, source) {
  out <- data.frame(
    name = names(definitions),
    table = table,
    source = source
  )
  for (field in definition_scalar_fields) {
    out[[field]] <- vapply(
      definitions,
      function(def) def[[field]] %||% NA_character_,
      character(1)
    )
  }
  out$mixed_grain <- definition_mixed_grain(definitions)
  for (field in definition_list_fields) {
    out[[field]] <- I(lapply(definitions, function(def) def[[field]]))
  }
  out
}

definition_mixed_grain <- function(definitions) {
  mixed <- vapply(definitions, definition_is_mixed_grain, logical(1))

  repeat {
    inherited <- vapply(
      definitions,
      function(definition) any(mixed[definition$definitions]),
      logical(1)
    )
    updated <- mixed | inherited
    if (identical(updated, mixed)) {
      return(unname(updated))
    }
    mixed <- updated
  }
}

definition_is_mixed_grain <- function(definition) {
  # Exported kind alone does not expose a row expression's aggregate child.
  ir <- attr(definition, "ir", exact = TRUE)
  identical(ir$shape, "row") && definition_ir_has_aggregate(ir)
}

definition_ir_has_aggregate <- function(node) {
  if (!is.list(node)) {
    return(FALSE)
  }
  if (identical(node$shape, "agg")) {
    return(TRUE)
  }
  any(vapply(node, definition_ir_has_aggregate, logical(1)))
}

registry_defs <- function(registry, source = NULL) {
  defs <- registry$defs
  if (is.null(source)) {
    return(defs)
  }
  defs[defs$source == source, ]
}

definition_token_pattern <-
  "\\{\\{\\s*([^{}]+?)\\s*\\}\\}"

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
      sprintf("(%s)", def$sql),
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
  separator <- regexpr("::", token, fixed = TRUE)[[1]]
  if (separator > 0L) {
    table <- substr(token, 1L, separator - 1L)
    name <- substr(token, separator + 2L, nchar(token))
    return(resolve_qualified_definition(table, name, token, sql, defs, call))
  }

  named <- defs[defs$name == token, ]
  if (nrow(named) == 0) {
    legacy <- grepl(
      "^[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)+$",
      token
    )
    if (!legacy) {
      abort_unknown_token(token, defs, call = call)
    }
    parts <- strsplit(token, ".", fixed = TRUE)[[1]]
    name <- utils::tail(parts, 1L)
    table <- paste(utils::head(parts, -1L), collapse = ".")
    return(resolve_qualified_definition(table, name, token, sql, defs, call))
  }

  in_scope <- named[
    vapply(
      named$table,
      function(table) definition_table_in_query(table, sql),
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
  qualified <- sprintf("{{%s::%s}}", in_scope$table, token)
  cli::cli_abort(
    c(
      "{.code {{{{{token}}}}}} is ambiguous here: it is defined on several
       tables in this query.",
      i = "Qualify the token: {.or {.code {qualified}}}."
    ),
    call = call
  )
}

resolve_qualified_definition <- function(table, name, token, sql, defs, call) {
  hits <- defs[defs$table == table & defs$name == name, ]
  if (nrow(hits) == 0L) {
    abort_unknown_token(token, defs, call = call)
  }
  if (!definition_table_in_query(table, sql)) {
    cli::cli_abort(
      "{.code {{{{{token}}}}}} is defined on table {.val {table}}, which does
       not appear in this query.",
      call = call
    )
  }
  hits[1, ]
}

definition_table_in_query <- function(table, sql) {
  sql <- gsub(definition_token_pattern, "", sql, perl = TRUE)
  grepl(word_pattern(table), sql, ignore.case = TRUE)
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
  kind <- defs$kind
  label <- flatten_inline(ifelse(is.na(defs$label), "", defs$label))
  item <- ifelse(
    nzchar(label),
    sprintf("`{{%s}}` (%s)", defs$name, label),
    sprintf("`{{%s}}`", defs$name)
  )

  groups <- c(
    filter = "filters",
    derived = "derived",
    metric = "metrics"
  )
  vapply(
    unique(scope),
    function(one) {
      parts <- vapply(
        intersect(names(groups), kind[scope == one]),
        function(group) {
          sprintf(
            "%s %s",
            groups[[group]],
            paste(item[scope == one & kind == group], collapse = ", ")
          )
        },
        character(1)
      )
      sprintf("- %s: %s", one, paste(parts, collapse = "; "))
    },
    character(1)
  )
}

definitions_entry_text <- function(definitions) {
  if (length(definitions) == 0) {
    return(NULL)
  }
  paste0(
    paste0(
      "Governed definitions (write as `{{name}}` tokens in SQL; use ",
      "`{{table::name}}` to qualify):\n\n"
    ),
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
      notes <- def$notes %||% character()
      paste(
        c(
          sprintf("(%s, %s)", def$kind, def$type),
          if (nzchar(detail)) detail,
          sprintf("Expression: `%s`.", flatten_inline(def$expression)),
          if (!is.null(def$sql)) {
            sprintf(
              "Selected %s: `(%s)`.",
              def$target,
              flatten_inline(def$sql)
            )
          },
          if (length(notes)) {
            sprintf("Translation notes: %s", paste(notes, collapse = " "))
          }
        ),
        collapse = " "
      )
    },
    character(1)
  )
}

applied_definitions_text <- function(applied) {
  if (NROW(applied) == 0) {
    return(NULL)
  }
  lines <- vapply(
    seq_len(nrow(applied)),
    function(i) {
      notes <- applied$notes[[i]]
      paste(
        c(
          sprintf(
            "- {{%s}} (%s): expression `%s`; %s `(%s)`",
            applied$name[[i]],
            applied$table[[i]],
            flatten_inline(applied$expression[[i]]),
            applied$target[[i]],
            flatten_inline(applied$sql[[i]])
          ),
          if (length(notes)) {
            sprintf("  Translation notes: %s", paste(notes, collapse = " "))
          }
        ),
        collapse = "\n"
      )
    },
    character(1)
  )
  paste0("Applied governed definitions:\n\n", paste(lines, collapse = "\n"))
}

# Fields are absent as NULL in dictionary lists and NA in registry rows.
prose_detail <- function(description, details) {
  fields <- c(description, details)
  flatten_inline(paste(fields[!is.na(fields)], collapse = " "))
}

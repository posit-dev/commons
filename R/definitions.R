# Definitions: governed SQL expressions authored in a data dictionary's
# per-table `definitions` field. Each is a named, parameterless expression
# over one table's rows with a declared data-dict type; boolean definitions
# act as filters, aggregates as metrics, everything else as dimensions. The
# model writes them as `{{name}}` tokens in run_sql SQL and commons expands
# each token to its governed expression before the query runs, so the
# trusted fragment lands byte-exact and usage is machine-detectable.
#
# The `definitions` field anticipates the data-dict spec sketched in
# tidyverse/data-dict#134 (envelope of name/label/description/details/expr/
# type, plus values for enums; bare-name references to sibling definitions).
# Two deliberate departures until that spec ships: expressions are warehouse
# SQL rather than data-dict's constrained grammar (exprs authored in the
# grammar, a strict SQL subset, run unchanged), and validation binds against
# the live source rather than parsing. Revisit when data-dict cuts the spec.

# ---- dictionary parsing ------------------------------------------------------

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
      token_example <- sprintf("{{%s}}", name)
      cli::cli_abort(
        c(
          "Definition names must be identifiers (letters, digits, and
           underscores); {.val {name}} on table {.val {table}} is not.",
          i = "Names become tokens like {.code {token_example}} in SQL and
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
    def$description <- prose_field(def$description)
    def$details <- prose_field(def$details)
    definitions[[name]] <- def
  }

  # The spec requires names unique within their scope, including amongst the
  # table's variables; a definition shadowing a column would silently change
  # what sibling references to that name mean.
  shadowed <- intersect(names(definitions), columns)
  if (length(shadowed)) {
    cli::cli_abort(
      "Definitions on table {.val {table}} must not share a name with its
       documented columns: {.val {shadowed}}.",
      call = call
    )
  }

  resolve_definition_references(definitions, table, call = call)
}

# A bare name in an expr that matches a sibling definition on the same table
# refers to it (per the #134 spec, e.g. `SUM(total) FILTER (WHERE realized)`).
# Resolve recursively into `expanded` so every consumer splices
# fully-resolved SQL, erroring on reference cycles.
resolve_definition_references <- function(
  definitions,
  table,
  call = rlang::caller_env()
) {
  resolving <- character()
  expanded <- list()

  resolve <- function(name) {
    if (!is.null(expanded[[name]])) {
      return(expanded[[name]])
    }
    if (name %in% resolving) {
      chain <- paste(c(resolving, name), collapse = " -> ")
      cli::cli_abort(
        "Definitions on table {.val {table}} reference each other in a
         cycle: {chain}.",
        call = call
      )
    }
    resolving <<- c(resolving, name)
    expr <- definitions[[name]]$expr
    for (sibling in names(definitions)) {
      if (!grepl(word_pattern(sibling), strip_sql_literals(expr))) {
        next
      }
      expr <- gsub_outside_literals(
        expr,
        word_pattern(sibling),
        sprintf("(%s)", resolve(sibling))
      )
    }
    resolving <<- setdiff(resolving, name)
    expanded[[name]] <<- expr
    expr
  }

  for (name in names(definitions)) {
    definitions[[name]]$expanded <- resolve(name)
  }
  definitions
}

# Substitute outside single-quoted SQL string literals, so a definition
# named like a word inside a literal ('deduplicated') is left alone.
gsub_outside_literals <- function(x, pattern, replacement) {
  matches <- gregexpr(sql_literal_pattern, x, perl = TRUE)[[1]]
  # gsub replacement treats backslashes and backreferences specially; the
  # substituted text is literal SQL.
  replacement <- gsub("\\", "\\\\", replacement, fixed = TRUE)
  if (matches[[1]] == -1) {
    return(gsub(pattern, replacement, x))
  }

  starts <- as.integer(matches)
  lengths <- attr(matches, "match.length")
  out <- character()
  pos <- 1L
  for (i in seq_along(starts)) {
    code <- substr(x, pos, starts[[i]] - 1L)
    out <- c(
      out,
      gsub(pattern, replacement, code),
      substr(x, starts[[i]], starts[[i]] + lengths[[i]] - 1L)
    )
    pos <- starts[[i]] + lengths[[i]]
  }
  out <- c(out, gsub(pattern, replacement, substr(x, pos, nchar(x))))
  paste(out, collapse = "")
}

strip_sql_literals <- function(x) {
  gsub(sql_literal_pattern, "''", x, perl = TRUE)
}

sql_literal_pattern <- "'(?:[^']|'')*'"

# ---- registry ----------------------------------------------------------------

# Every source's definitions in one flat list, held in an environment so
# validation state written lazily (board sources bind at first expansion) is
# seen by every holder. Records carry the source's label so token resolution
# in run_sql can scope to the query's source.
definitions_registry <- function(sources, call = rlang::caller_env()) {
  registry <- new.env(parent = emptyenv())
  registry$records <- list()

  labels <- rlang::names2(sources)
  for (i in seq_along(sources)) {
    source <- sources[[i]]
    dictionary <- source$dictionary
    for (table in names(dictionary$tables)) {
      definitions <- dictionary$tables[[table]]$definitions
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
      for (name in names(definitions)) {
        def <- definitions[[name]]
        registry$records[[length(registry$records) + 1]] <- list(
          name = name,
          table = table,
          source = labels[[i]],
          type = def$type,
          role = if (definition_base_type(def$type) == "boolean") {
            "filter"
          } else {
            NA_character_
          },
          description = def$description,
          details = def$details,
          expr = def$expr,
          expanded = def$expanded,
          validated = FALSE
        )
      }
    }
  }
  registry
}

registry_records <- function(registry, source_label = NULL) {
  records <- registry$records %||% list()
  if (is.null(source_label)) {
    return(records)
  }
  records[vapply(
    records,
    function(record) identical(record$source, source_label),
    logical(1)
  )]
}

registry_update <- function(registry, record) {
  for (i in seq_along(registry$records)) {
    existing <- registry$records[[i]]
    if (
      identical(existing$source, record$source) &&
        identical(existing$table, record$table) &&
        identical(existing$name, record$name)
    ) {
      registry$records[[i]] <- record
      break
    }
  }
  invisible(registry)
}

# ---- validation --------------------------------------------------------------

# Connection and frame sources already answer live queries at data_source()
# time, so their definitions bind at agent construction too, failing fast
# with the definition named. Board sources are skipped here: their pins load
# lazily (#43), so they validate at first expansion instead.
validate_eager_definitions <- function(
  registry,
  sources,
  call = rlang::caller_env()
) {
  labels <- rlang::names2(sources)
  for (i in seq_along(sources)) {
    if (is.null(sources[[i]]$pending)) {
      validate_source_definitions(
        registry,
        sources[[i]],
        labels[[i]],
        call = call
      )
    }
  }
  invisible(registry)
}

# Bind a source's definitions against its live database. Runs at agent
# construction for connection and frame sources, whose construction already
# issues live queries; board sources load pins lazily (#43), so their
# definitions validate at first expansion instead, with the same
# definition-named error. Probes go through source_query() so a pending pin
# materializes on demand.
validate_source_definitions <- function(
  registry,
  source,
  source_label,
  call = rlang::caller_env()
) {
  for (record in registry_records(registry, source_label)) {
    if (record$validated) {
      next
    }
    registry_update(registry, validate_definition(source, record, call = call))
  }
  invisible(registry)
}

validate_definition <- function(source, record, call = rlang::caller_env()) {
  id <- DBI::dbQuoteIdentifier(source$con, source$table_ids[[record$table]])

  # Portable across DBI backends, unlike DuckDB's DESCRIBE: bind the
  # expression in a zero-row query and type-check the R class of the result.
  probe <- try_source_query(
    source,
    sprintf("SELECT (%s) AS x FROM %s WHERE 1 = 0", record$expanded, id)
  )
  if (inherits(probe, "condition")) {
    cli::cli_abort(
      c(
        "Definition {.val {record$name}} on table {.val {record$table}}
         does not bind against the data source.",
        i = "Its expression expands to {.code {record$expanded}}."
      ),
      parent = probe,
      call = call
    )
  }
  check_definition_type(record, probe$x, call = call)

  if (identical(record$role, "filter")) {
    where <- try_source_query(
      source,
      sprintf(
        "SELECT 1 AS x FROM %s WHERE (%s) AND (1 = 0)",
        id,
        record$expanded
      )
    )
    if (inherits(where, "condition")) {
      cli::cli_abort(
        c(
          "Boolean definition {.val {record$name}} on table
           {.val {record$table}} can't filter rows.",
          i = "Its expression aggregates over rows (or uses a window
           function), so it has no per-row value. Restate it per row, or
           declare a non-boolean type."
        ),
        call = call
      )
    }
    record$validated <- TRUE
    return(record)
  }

  # Aggregates are illegal in GROUP BY, so a bind failure there classifies
  # the expression as a metric; anything that groups is a dimension. (The
  # constrained data-dict grammar will make this parse-level someday.)
  grouped <- try_source_query(
    source,
    sprintf(
      "SELECT 1 AS x FROM %s WHERE 1 = 0 GROUP BY (%s)",
      id,
      record$expanded
    )
  )
  record$role <- if (inherits(grouped, "condition")) "metric" else "dimension"
  record$validated <- TRUE
  record
}

try_source_query <- function(source, sql) {
  tryCatch(source_query(source, sql), error = function(err) err)
}

# Coarser than SQL types but portable: compare the declared data-dict type
# against the R class of the probe column. Unknown declared types and
# unmapped classes pass rather than guess.
check_definition_type <- function(record, column, call = rlang::caller_env()) {
  compatible <- switch(
    definition_base_type(record$type),
    boolean = is.logical(column),
    number = is.numeric(column) || inherits(column, "integer64"),
    string = ,
    enum = is.character(column) || is.factor(column),
    date = inherits(column, "Date"),
    datetime = ,
    timestamp = inherits(column, "POSIXt"),
    NA
  )
  if (isFALSE(compatible)) {
    cli::cli_abort(
      "Definition {.val {record$name}} on table {.val {record$table}} is
       declared {.val {record$type}} but its expression returns
       {.cls {class(column)[[1]]}}.",
      call = call
    )
  }
  invisible(record)
}

definition_base_type <- function(type) {
  tolower(sub("\\(.*$", "", trimws(type)))
}

# ---- expansion ---------------------------------------------------------------

definition_token_pattern <-
  "\\{\\{\\s*([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)?)\\s*\\}\\}"

# The expansion step of run_sql: resolve each {{name}} / {{table.name}}
# token in the model's SQL to a definition of the query's source and splice
# in its governed expression. Runs before check_query(), so the denylist
# sees the SQL that will actually execute. `source_name` is the tool
# argument, NULL when the agent has a single source.
expand_for_run_sql <- function(registry, sources, source, source_name, sql) {
  if (is.null(registry) || length(registry$records) == 0) {
    return(list(sql = sql, applied = list()))
  }
  label <- source_name %||% rlang::names2(sources)[[1]]
  expansion <- expand_definitions(sql, registry_records(registry, label))
  # A lazy board source hasn't bound its definitions yet; do it at this
  # first use so a broken definition fails with its name, not a SQL error.
  if (length(expansion$applied) > 0) {
    validate_source_definitions(registry, source, label)
  }
  expansion
}

expand_definitions <- function(sql, records, call = rlang::caller_env()) {
  matches <- regmatches(
    sql,
    gregexpr(definition_token_pattern, sql, perl = TRUE)
  )[[1]]
  if (length(matches) == 0) {
    return(list(sql = sql, applied = list()))
  }

  tokens <- unique(gsub("\\{\\{\\s*|\\s*\\}\\}", "", matches))
  applied <- list()
  for (token in tokens) {
    record <- resolve_definition_token(token, sql, records, call = call)
    replacement <- gsub(
      "\\",
      "\\\\",
      sprintf("(%s)", record$expanded),
      fixed = TRUE
    )
    sql <- gsub(
      sprintf("\\{\\{\\s*%s\\s*\\}\\}", escape_regex(token)),
      replacement,
      sql
    )
    applied[[length(applied) + 1]] <- record
  }
  list(sql = sql, applied = applied)
}

# A bare token resolves against the definitions whose table appears in the
# query text (the same word-match heuristic dictionary_sql_entries() uses),
# so same-named definitions on different tables coexist; {{table.name}} is
# always accepted as the explicit tiebreaker. Failures are tool errors the
# model can recover from in-conversation.
resolve_definition_token <- function(
  token,
  sql,
  records,
  call = rlang::caller_env()
) {
  token_text <- sprintf("{{%s}}", token)

  if (grepl(".", token, fixed = TRUE)) {
    parts <- strsplit(token, ".", fixed = TRUE)[[1]]
    hits <- records[vapply(
      records,
      function(record) {
        identical(record$table, parts[[1]]) && identical(record$name, parts[[2]])
      },
      logical(1)
    )]
    if (length(hits) == 0) {
      abort_unknown_token(token_text, records, call = call)
    }
    return(hits[[1]])
  }

  named <- records[vapply(
    records,
    function(record) identical(record$name, token),
    logical(1)
  )]
  if (length(named) == 0) {
    abort_unknown_token(token_text, records, call = call)
  }

  in_scope <- named[vapply(
    named,
    function(record) grepl(word_pattern(record$table), sql, ignore.case = TRUE),
    logical(1)
  )]
  if (length(in_scope) == 1) {
    return(in_scope[[1]])
  }

  tables <- vapply(named, function(record) record$table, character(1))
  if (length(in_scope) == 0) {
    cli::cli_abort(
      "{.code {token_text}} is defined on table{?s} {.val {tables}},
       which {?does/do} not appear in this query.",
      call = call
    )
  }
  qualified <- sprintf("`{{%s.%s}}`", tables, token)
  cli::cli_abort(
    c(
      "{.code {token_text}} is ambiguous here: it is defined on several
       tables in this query.",
      i = "Qualify the token: {.or {qualified}}."
    ),
    call = call
  )
}

abort_unknown_token <- function(token_text, records, call) {
  if (length(records) == 0) {
    cli::cli_abort(
      c(
        "No governed definition matches {.code {token_text}}.",
        i = "This source has no governed definitions."
      ),
      call = call
    )
  }
  available <- vapply(
    records,
    function(record) sprintf("{{%s}} (%s)", record$name, record$table),
    character(1)
  )
  cli::cli_abort(
    c(
      "No governed definition matches {.code {token_text}}.",
      i = "Available definitions: {.code {available}}."
    ),
    call = call
  )
}

# ---- delivery ----------------------------------------------------------------

# The ambient system-prompt section: one line per definition, grouped by
# role, capped like the glossary so a large roster degrades to search and
# first-touch delivery rather than bloating every prompt. Only the
# boolean -> filter split is known from type alone at prompt time (lazy
# sources haven't been probed yet), so non-boolean definitions group
# together as expressions.
definitions_prompt_text <- function(registry, cap_chars = 4000) {
  records <- registry_records(registry)
  if (length(records) == 0) {
    return("")
  }

  multi_source <- length(unique(vapply(
    records,
    function(record) record$source,
    character(1)
  ))) > 1
  lines <- vapply(
    records,
    function(record) definition_line(record, multi_source),
    character(1)
  )
  ambient <- cumsum(nchar(lines)) <= cap_chars
  # Telling the model the list is complete is what saves it a verification
  # search; when the roster overflows the cap, search_pool exists to find
  # the rest (see pool_searchable()).
  overflow <- if (all(ambient)) {
    "This is the complete set of governed definitions."
  } else {
    "More definitions arrive with their tables' dictionary entries, via context search, and via search_pool."
  }

  filter <- vapply(
    records,
    function(record) identical(record$role, "filter"),
    logical(1)
  )
  blocks <- c(
    if (any(filter & ambient)) {
      paste0(
        "Filters (boolean; use in WHERE):\n",
        paste(lines[filter & ambient], collapse = "\n")
      )
    },
    if (any(!filter & ambient)) {
      paste0(
        "Expressions (use in SELECT or GROUP BY; expansion can't add an ",
        "alias, so write `SELECT {{name}} AS name`. Metric expressions ",
        "are already aggregates --- never wrap one in SUM() or another ",
        "aggregate):\n",
        paste(lines[!filter & ambient], collapse = "\n")
      )
    },
    overflow
  )

  paste0(
    "\n\n# Governed definitions\n\n",
    "Trusted expressions from the data dictionary. Write them as `{{name}}` ",
    "tokens anywhere in `run_sql` SQL (or `{{table.name}}` when a name ",
    "exists on several tables); each token expands to its governed SQL ",
    "before the query runs.\n\n",
    paste(blocks, collapse = "\n\n")
  )
}

# Whether the definitions roster exceeds the ambient prompt cap, leaving
# some discoverable only by search.
definitions_overflow <- function(registry, cap_chars = 4000) {
  records <- registry_records(registry)
  if (length(records) == 0) {
    return(FALSE)
  }
  lines <- vapply(records, definition_line, character(1))
  !all(cumsum(nchar(lines)) <= cap_chars)
}

definition_line <- function(record, multi_source = FALSE) {
  scope <- if (multi_source && nzchar(record$source)) {
    sprintf("%s.%s", record$source, record$table)
  } else {
    record$table
  }
  line <- sprintf("- `{{%s}}` (%s)", record$name, scope)
  detail <- flatten_inline(paste(
    c(record$description %||% character(), record$details %||% character()),
    collapse = " "
  ))
  if (nzchar(detail)) {
    line <- paste0(line, ": ", detail)
  }
  line
}

# The definitions block of a table's first-touch dictionary entry, with full
# expansions so the model sees exactly what each token stands for without a
# context search.
definitions_entry_text <- function(definitions) {
  if (length(definitions) == 0) {
    return(NULL)
  }
  lines <- vapply(
    names(definitions),
    function(name) {
      def <- definitions[[name]]
      line <- sprintf("- `{{%s}}` (%s)", name, def$type)
      detail <- flatten_inline(paste(
        c(def$description %||% character(), def$details %||% character()),
        collapse = " "
      ))
      if (nzchar(detail)) {
        line <- paste0(line, ": ", detail)
      }
      sprintf("%s Expands to `(%s)`.", line, flatten_inline(def$expanded))
    },
    character(1)
  )
  paste0(
    "Governed definitions (write as `{{name}}` tokens in SQL):\n\n",
    paste(lines, collapse = "\n")
  )
}

# One searchable chunk per definition, indexed with the rest of the
# dictionary prose so definitions are retrievable and citable.
definition_context_chunks <- function(dictionary) {
  unlist(lapply(names(dictionary$tables), function(table) {
    definitions <- dictionary$tables[[table]]$definitions
    vapply(
      names(definitions),
      function(name) {
        def <- definitions[[name]]
        detail <- flatten_inline(paste(
          c(def$description %||% character(), def$details %||% character()),
          collapse = " "
        ))
        sprintf(
          "Governed definition `{{%s}}` on table `%s` (%s): %s Expands to `(%s)`.",
          name,
          table,
          def$type,
          detail,
          flatten_inline(def$expanded)
        )
      },
      character(1)
    )
  }))
}

# The note appended to a run_sql result confirming which definitions were
# applied, so usage is auditable from the transcript.
applied_definitions_text <- function(applied) {
  if (length(applied) == 0) {
    return(NULL)
  }
  lines <- vapply(
    applied,
    function(record) {
      sprintf(
        "- {{%s}} (%s) expanded to `(%s)`",
        record$name,
        record$table,
        flatten_inline(record$expanded)
      )
    },
    character(1)
  )
  paste0("Applied governed definitions:\n\n", paste(lines, collapse = "\n"))
}

# Composed from what the agent actually has: the measure-fallback framing
# only when measures exist, the token surface only when a dictionary
# declares definitions. For a definitions-only agent, run_sql isn't a
# fallback from the governed path --- it's the vehicle for it.
run_sql_description <- function(definitions, measures = list()) {
  parts <- c(
    "Run a read-only SELECT query against a data source.",
    if (length(measures) > 0) {
      "Use this when no registered measure answers the question."
    },
    if (!is.null(definitions) && length(registry_records(definitions)) > 0) {
      paste0(
        "Governed definitions (see the system prompt) can be written as ",
        "{{name}} tokens anywhere in the SQL; each expands to its trusted ",
        "expression before the query runs."
      )
    }
  )
  paste(parts, collapse = " ")
}

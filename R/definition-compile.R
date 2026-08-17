# Export records stay source-independent until a source supplies
# the destination target and its authored-to-physical catalog bindings.

definition_compile_source <- function(
  raw,
  source,
  call = rlang::caller_env()
) {
  definition_bind_export(
    definition_export_spec(raw, call = call),
    source,
    call = call
  )
}

definition_bind_export <- function(
  export,
  source,
  call = rlang::caller_env()
) {
  check_data_source(source, call = call)
  tables <- export$tables[vapply(
    export$tables,
    function(table) length(table$definitions) > 0L,
    logical(1)
  )]
  definition_names <- unlist(lapply(tables, function(table) {
    vapply(table$definitions, `[[`, character(1), "name")
  }))
  target <- definition_source_target(
    source,
    definition_names,
    call = call
  )
  tables <- lapply(tables, function(table) {
    binding <- definition_source_binding(source, table$name, call = call)
    markers <- definition_reference_markers(table$definitions, binding)
    definitions <- lapply(table$definitions, function(definition) {
      definition_bind_one(
        definition,
        table$name,
        binding,
        target,
        markers,
        call = call
      )
    })
    names(definitions) <- vapply(
      table$definitions,
      `[[`,
      character(1),
      "name"
    )
    definitions <- definition_compose_table(
      definitions,
      binding$table,
      target,
      call = call
    )
    list(
      name = binding$table,
      authored_name = table$name,
      definitions = unname(definitions)
    )
  })
  names(tables) <- vapply(tables, `[[`, character(1), "name")
  list(target = target, tables = tables)
}

definition_bind_one <- function(
  definition,
  table,
  binding,
  target,
  markers,
  call
) {
  ir <- attr(definition, "ir", exact = TRUE)
  if (is.null(ir)) {
    cli::cli_abort(
      "Definition {.val {definition$name}} on table {.val {table}} has no typed expression available for SQL translation.",
      call = call
    )
  }
  selection <- attr(definition, "selection", exact = TRUE)
  translations <- lapply(
    definition_sql_targets,
    definition_emit_translation,
    ir = ir,
    selection = selection
  )
  bound_ir <- definition_bind_ir(
    ir,
    binding$columns,
    binding$strict,
    definition$name,
    table,
    call
  )
  bound_selection <- definition_bind_selection(
    selection,
    binding$columns,
    binding$strict,
    definition$name,
    table,
    call
  )
  execution_ir <- definition_mark_references(bound_ir, markers)
  selected <- definition_emit_translation(
    target,
    execution_ir,
    bound_selection
  )
  if (!is.null(selected$error)) {
    cli::cli_abort(
      c(
        "Definition {.val {definition$name}} on table {.val {binding$table}} cannot be compiled for {.val {target}}.",
        i = selected$error
      ),
      call = call
    )
  }
  definition$translations <- translations
  definition$target <- target
  definition$sql <- selected$code
  definition$notes <- selected$notes
  attr(definition, "ir") <- bound_ir
  attr(definition, "selection") <- bound_selection
  attr(definition, "composition_markers") <- unname(
    markers[definition$definitions]
  )
  definition
}

definition_reference_markers <- function(definitions, binding) {
  used <- c(
    vapply(definitions, `[[`, character(1), "name"),
    names(binding$columns),
    unname(binding$columns),
    unlist(lapply(definitions, function(definition) {
      definition_ir_identifiers(attr(definition, "ir", exact = TRUE))
    }))
  )
  used <- used[!is.na(used)]
  markers <- character(length(definitions))
  names(markers) <- vapply(definitions, `[[`, character(1), "name")
  for (i in seq_along(markers)) {
    marker <- sprintf("__commons_definition_reference_%03d__", i)
    while (marker %in% c(used, markers)) {
      marker <- paste0(marker, "_")
    }
    markers[[i]] <- marker
  }
  markers
}

definition_ir_identifiers <- function(node) {
  if (!is.list(node)) {
    return(character())
  }
  current <- if (identical(node$kind, "column")) node$path else character()
  unique(c(
    current,
    unlist(lapply(node, definition_ir_identifiers), use.names = FALSE)
  ))
}

definition_mark_references <- function(node, markers) {
  if (!is.list(node)) {
    return(node)
  }
  if (
    identical(node$kind, "column") &&
      identical(node$reference, "definition")
  ) {
    node$path[[1]] <- markers[[node$path[[1]]]]
  }
  lapply(
    node,
    definition_mark_references,
    markers = markers
  )
}

definition_emit_translation <- function(target, ir, selection) {
  emitted <- switch(
    target,
    `SQL(duckdb)` = {
      out <- definition_emit_duckdb(ir, selection)
      list(code = out$code, error = NULL, notes = out$notes)
    },
    `SQL(snowflake)` = definition_emit_sql(ir, "snowflake", selection),
    `SQL(databricks)` = definition_emit_sql(ir, "databricks", selection)
  )
  c(list(target = target), emitted)
}

definition_source_target <- function(
  source,
  definitions,
  call = rlang::caller_env()
) {
  if (length(definitions) == 0L) {
    return(NULL)
  }
  con <- source$con
  if (inherits(con, "duckdb_connection")) {
    return("SQL(duckdb)")
  }
  if (is_snowflake_connection(con)) {
    return("SQL(snowflake)")
  }
  if (is_databricks_connection(con)) {
    return("SQL(databricks)")
  }
  dialect <- source_dialect(source)
  cli::cli_abort(
    "Definitions {.val {definitions}} cannot be compiled for data source backend {.val {dialect}}.",
    call = call
  )
}

definition_source_binding <- function(source, table, call) {
  bindings <- source$definition_bindings
  if (is.null(bindings)) {
    if (!table %in% source$tables) {
      cli::cli_abort(
        "The data dictionary declares definitions on table {.val {table}}, which the data source does not expose.",
        call = call
      )
    }
    return(list(table = table, columns = NULL, strict = FALSE))
  }
  selected <- bindings$tables[[table]]
  if (is.null(selected) || is.na(selected)) {
    cli::cli_abort(
      "Authored table {.val {table}} with definitions does not match an exposed relation.",
      call = call
    )
  }
  list(
    table = selected,
    columns = bindings$columns[[table]],
    strict = isTRUE(bindings$strict)
  )
}

definition_bind_ir <- function(
  node,
  columns,
  strict,
  definition,
  table,
  call
) {
  if (!is.list(node)) {
    return(node)
  }
  if (
    identical(node$kind, "column") &&
      !identical(node$reference, "definition")
  ) {
    node$path <- definition_bind_column_path(
      node$path,
      columns,
      strict,
      definition,
      table,
      call
    )
  }
  lapply(
    node,
    definition_bind_ir,
    columns = columns,
    strict = strict,
    definition = definition,
    table = table,
    call = call
  )
}

definition_bind_selection <- function(
  selection,
  columns,
  strict,
  definition,
  table,
  call
) {
  if (is.null(selection)) {
    return(NULL)
  }
  selection$columns <- lapply(selection$columns, function(column) {
    column$path <- definition_bind_column_path(
      column$path,
      columns,
      strict,
      definition,
      table,
      call
    )
    column
  })
  selection
}

definition_bind_column_path <- function(
  path,
  columns,
  strict,
  definition,
  table,
  call
) {
  if (is.null(columns)) {
    return(path)
  }
  physical <- columns[[path[[1]]]]
  if (is.null(physical) || is.na(physical)) {
    if (strict) {
      cli::cli_abort(
        "Definition {.val {definition}} on table {.val {table}} references authored column {.val {path[[1]]}}, which is absent from the selected relation.",
        call = call
      )
    }
    return(path)
  }
  path[[1]] <- physical
  path
}

definition_compose_table <- function(
  definitions,
  table,
  target,
  call = rlang::caller_env()
) {
  if (length(definitions) == 0L) {
    return(definitions)
  }
  composed <- list()
  pending <- names(definitions)
  while (length(pending)) {
    ready <- pending[vapply(
      pending,
      function(name) {
        all(definitions[[name]]$definitions %in% names(composed))
      },
      logical(1)
    )]
    if (length(ready) == 0L) {
      cli::cli_abort(
        "Definitions on table {.val {table}} cannot be composed because their dependency graph is unresolved: {.val {pending}}.",
        call = call
      )
    }
    for (name in ready) {
      definition <- definitions[[name]]
      references <- definition$definitions
      replacements <- vapply(
        references,
        function(reference) composed[[reference]]$sql,
        character(1)
      )
      names(replacements) <- attr(
        definition,
        "composition_markers",
        exact = TRUE
      )
      definition$sql <- definition_compose_identifiers(
        definition$sql,
        replacements,
        target
      )
      dependency_notes <- unlist(
        lapply(references, function(reference) composed[[reference]]$notes),
        use.names = FALSE
      )
      definition$notes <- sort(unique(c(definition$notes, dependency_notes)))
      composed[[name]] <- definition
    }
    pending <- setdiff(pending, ready)
  }
  composed[names(definitions)]
}

definition_compose_identifiers <- function(code, replacements, target) {
  if (length(replacements) == 0L) {
    return(code)
  }
  quote <- if (identical(target, "SQL(databricks)")) "`" else '"'
  chars <- strsplit(code, "", fixed = TRUE)[[1]]
  out <- character()
  i <- 1L
  while (i <= length(chars)) {
    char <- chars[[i]]
    if (identical(char, "'")) {
      token <- definition_take_quoted(chars, i, "'")
      out <- c(out, token$text)
      i <- token$next_index
      next
    }
    if (identical(char, quote)) {
      token <- definition_take_quoted(chars, i, quote)
      name <- definition_unquote_identifier(token$text, quote)
      replacement <- if (name %in% names(replacements)) {
        replacements[[name]]
      }
      out <- c(
        out,
        if (is.null(replacement)) token$text else paste0("(", replacement, ")")
      )
      i <- token$next_index
      next
    }
    out <- c(out, char)
    i <- i + 1L
  }
  paste0(out, collapse = "")
}

definition_take_quoted <- function(chars, start, quote) {
  out <- quote
  i <- start + 1L
  while (i <= length(chars)) {
    char <- chars[[i]]
    out <- c(out, char)
    if (identical(char, quote)) {
      if (i < length(chars) && identical(chars[[i + 1L]], quote)) {
        out <- c(out, quote)
        i <- i + 2L
        next
      }
      return(list(text = paste0(out, collapse = ""), next_index = i + 1L))
    }
    i <- i + 1L
  }
  cli::cli_abort("Generated SQL contains an unterminated quoted value.")
}

definition_unquote_identifier <- function(token, quote) {
  value <- substr(token, 2L, nchar(token) - 1L)
  gsub(paste0(quote, quote), quote, value, fixed = TRUE)
}

definition_sql_targets <- c(
  "SQL(duckdb)",
  "SQL(snowflake)",
  "SQL(databricks)"
)

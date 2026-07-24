# The pool-facing surfaces of the semantic layer: query_metrics, the
# compiled query tool over dictionary metrics, and search_pool, the one
# discovery surface spanning measures and definitions.

# ---- query_metrics -----------------------------------------------------------

# The compiled query surface over dictionary metrics, in the shape semantic
# layers converge on (MetricFlow's query(metrics, group_by, where),
# Snowflake's SEMANTIC_VIEW): one tool over the pool. Metric, dimension, and
# filter names are passed as strings and validated at call time against the
# registry --- the call_measure convention --- so nothing depends on lazy
# board sources being probed before tool registration.
query_metrics_impl <- function(
  registry,
  sources,
  handles,
  metrics,
  dimensions = NULL,
  filters = NULL,
  where = NULL,
  source_name = NULL
) {
  source <- resolve_sql_source(sources, source_name)
  label <- source_name %||% rlang::names2(sources)[[1]]
  validate_source_definitions(registry, source, label)
  records <- registry_records(registry, label)

  metric_records <- lapply(
    metrics,
    function(name) resolve_pool_name(name, records, role = "metric")
  )
  tables <- unique(vapply(metric_records, function(r) r$table, character(1)))
  if (length(tables) > 1) {
    cli::cli_abort(
      c(
        "Metrics in one query must share a table; these span {.val {tables}}.",
        i = "Query them separately and combine the results with run_r."
      )
    )
  }
  table <- tables[[1]]
  on_table <- records[vapply(
    records,
    function(record) identical(record$table, table),
    logical(1)
  )]
  columns <- names(source$dictionary$tables[[table]]$columns)

  con <- source$con
  id <- DBI::dbQuoteIdentifier(con, source$table_ids[[table]])
  dims <- lapply(
    dimensions %||% character(),
    function(name) resolve_query_dimension(name, on_table, columns, con)
  )
  filter_records <- lapply(
    filters %||% character(),
    function(name) resolve_pool_name(name, on_table, role = "filter")
  )
  conditions <- c(
    vapply(
      filter_records,
      function(record) sprintf("(%s)", record$expanded),
      character(1)
    ),
    vapply(
      normalize_where(where),
      function(triple) compile_where_triple(triple, columns, con),
      character(1)
    )
  )

  select <- c(
    vapply(
      dims,
      function(dim) {
        sprintf("%s AS %s", dim$sql, DBI::dbQuoteIdentifier(con, dim$name))
      },
      character(1)
    ),
    vapply(
      metric_records,
      function(record) {
        sprintf(
          "(%s) AS %s",
          record$expanded,
          DBI::dbQuoteIdentifier(con, record$name)
        )
      },
      character(1)
    )
  )
  sql <- sprintf("SELECT %s FROM %s", paste(select, collapse = ", "), id)
  if (length(conditions)) {
    sql <- sprintf("%s WHERE %s", sql, paste(conditions, collapse = " AND "))
  }
  if (length(dims)) {
    sql <- sprintf(
      "%s GROUP BY %s",
      sql,
      paste(vapply(dims, function(dim) dim$sql, character(1)), collapse = ", ")
    )
  }

  result <- source_query(source, sql)
  advert <- register_handle(handles, result)
  args <- drop_nulls(list(
    metrics = metrics,
    dimensions = dimensions,
    filters = filters
  ))
  tool_result(
    paste(c(df_to_markdown(result), advert), collapse = "\n\n"),
    title = sprintf(
      "Metrics: %s%s",
      html_escape(paste(metrics, collapse = ", ")),
      source_label(source_name)
    ),
    icon = maybe_icon("shield-check"),
    markdown = sprintf("```sql\n%s\n```\n\n%s", sql, df_to_markdown(result)),
    html = measure_display_html(args, result),
    tag = "A",
    show_tag = FALSE
  )
}

# Whether any definition could be a metric. Unvalidated records (lazy board
# sources) count: their role resolves at first call, and registering the
# tool can't wait for a probe that deliberately hasn't run.
registry_has_metrics <- function(registry) {
  any(vapply(
    registry_records(registry),
    function(record) is.na(record$role) || identical(record$role, "metric"),
    logical(1)
  ))
}

# The prompt teaches `{{name}}` for SQL, so models sometimes pass the
# braces here too; accept both forms.
strip_token_braces <- function(name) {
  gsub("^\\{\\{\\s*|\\s*\\}\\}$", "", trimws(name))
}

resolve_pool_name <- function(name, records, role) {
  name <- strip_token_braces(name)
  hits <- records[vapply(
    records,
    function(record) identical(record$name, name),
    logical(1)
  )]
  matched <- hits[vapply(
    hits,
    function(record) identical(record$role, role),
    logical(1)
  )]
  if (length(matched) >= 1) {
    return(matched[[1]])
  }
  if (length(hits)) {
    other <- hits[[1]]
    token <- sprintf("{{%s}}", name)
    cli::cli_abort(
      "{.val {name}} is a {other$role}, not a {role}; apply it as
       {.code {token}} in SQL instead."
    )
  }
  available <- vapply(records, function(record) record$name, character(1))
  roles <- vapply(records, function(record) record$role, character(1))
  cli::cli_abort(
    c(
      "No governed {role} is named {.val {name}}.",
      i = "Available {role}s: {.val {available[roles == role]}}."
    )
  )
}

# A dimension is either a dimension-role definition (grouped by its
# expression) or a documented column of the metric's table.
resolve_query_dimension <- function(name, records, columns, con) {
  name <- strip_token_braces(name)
  hits <- records[vapply(
    records,
    function(record) identical(record$name, name),
    logical(1)
  )]
  if (length(hits)) {
    record <- hits[[1]]
    if (!identical(record$role, "dimension")) {
      cli::cli_abort(
        "{.val {name}} is a {record$role} and can't be grouped by."
      )
    }
    return(list(sql = sprintf("(%s)", record$expanded), name = name))
  }
  if (name %in% columns) {
    return(list(
      sql = as.character(DBI::dbQuoteIdentifier(con, name)),
      name = name
    ))
  }
  dimension_names <- vapply(
    records[vapply(
      records,
      function(record) identical(record$role, "dimension"),
      logical(1)
    )],
    function(record) record$name,
    character(1)
  )
  cli::cli_abort(
    c(
      "No dimension or documented column is named {.val {name}}.",
      i = "Documented columns: {.val {columns}}.",
      i = if (length(dimension_names)) {
        "Governed dimensions: {.val {dimension_names}}."
      }
    )
  )
}

# ellmer may deliver an array of objects as a data frame or a list of named
# lists depending on the provider payload; normalize to a list of triples.
normalize_where <- function(where) {
  if (is.null(where) || length(where) == 0) {
    return(list())
  }
  if (is.data.frame(where)) {
    return(lapply(seq_len(nrow(where)), function(i) as.list(where[i, ])))
  }
  if (!is.null(names(where))) {
    return(list(as.list(where)))
  }
  lapply(where, as.list)
}

where_ops <- c("=", "!=", "<", "<=", ">", ">=")

compile_where_triple <- function(triple, columns, con) {
  for (field in c("column", "op", "value")) {
    value <- triple[[field]]
    if (length(value) != 1 || is.na(value) || !nzchar(as.character(value))) {
      cli::cli_abort(
        "Each {.arg where} entry needs {.field column}, {.field op}, and
         {.field value}."
      )
    }
    triple[[field]] <- as.character(value)
  }
  if (!triple$column %in% columns) {
    cli::cli_abort(
      c(
        "{.arg where} references {.val {triple$column}}, which is not a
         documented column.",
        i = "Documented columns: {.val {columns}}."
      )
    )
  }
  if (!triple$op %in% where_ops) {
    cli::cli_abort(
      "{.arg where} operator must be one of {.val {where_ops}},
       not {.val {triple$op}}."
    )
  }
  value <- if (grepl("^-?[0-9]+(\\.[0-9]+)?$", triple$value)) {
    triple$value
  } else {
    as.character(DBI::dbQuoteString(con, triple$value))
  }
  sprintf(
    "(%s %s %s)",
    DBI::dbQuoteIdentifier(con, triple$column),
    triple$op,
    value
  )
}

# ---- pool search -------------------------------------------------------------

# One discovery surface over the whole semantic layer: measures, metrics,
# dimensions, and filters, each labeled with its kind and how to invoke it.
# A metric hit carries its table's filters and dimensions alongside, as the
# available slicers.
search_pool_text <- function(
  measures,
  registry,
  query,
  source_names = character()
) {
  records <- registry_records(registry)
  if (length(measures) == 0 && length(records) == 0) {
    return("The semantic layer is empty.")
  }

  render <- c(
    lapply(measures, function(td) {
      function() measure_schema_text(td, source_names = source_names)
    }),
    lapply(records, function(record) {
      function() definition_pool_text(record, records)
    })
  )
  catalog <- c(
    vapply(
      measures,
      function(td) paste(tool_name(td), tool_description(td)),
      character(1)
    ),
    vapply(
      records,
      function(record) {
        paste(
          record$name,
          record$table,
          record$role,
          record$description,
          record$details
        )
      },
      character(1)
    )
  )

  hits <- lexical_rank(query, catalog, n = 5)
  if (length(hits) == 0) {
    return(sprintf(
      "Nothing in the semantic layer matches \"%s\". Consider writing a SQL query.",
      query
    ))
  }
  blocks <- vapply(render[hits], function(f) f(), character(1))
  paste(blocks, collapse = "\n\n")
}

definition_pool_text <- function(record, records) {
  role <- if (is.na(record$role)) "expression" else record$role
  detail <- flatten_inline(paste(
    c(record$description %||% character(), record$details %||% character()),
    collapse = " "
  ))
  invoke <- switch(
    role,
    filter = sprintf(
      "Apply in run_sql (e.g. `WHERE {{%s}}`) or as a query_metrics filter.",
      record$name
    ),
    metric = sprintf(
      "Query with query_metrics (metrics = [\"%s\"]) or in run_sql as `SELECT {{%s}} AS %s`.",
      record$name,
      record$name,
      record$name
    ),
    sprintf(
      "Use in run_sql SELECT or GROUP BY as `{{%s}}`, or as a query_metrics dimension.",
      record$name
    )
  )
  siblings <- if (identical(role, "metric")) {
    same_table <- records[vapply(
      records,
      function(r) identical(r$table, record$table) && !identical(r$name, record$name),
      logical(1)
    )]
    slicers <- vapply(
      same_table,
      function(r) {
        sprintf("{{%s}} (%s)", r$name, if (is.na(r$role)) "expression" else r$role)
      },
      character(1)
    )
    if (length(slicers)) {
      sprintf("Slicers on this table: %s.", paste(slicers, collapse = ", "))
    }
  }
  paste(
    c(
      sprintf(
        "### {{%s}} --- %s on table `%s`\n%s",
        record$name,
        role,
        record$table,
        detail
      ),
      invoke,
      siblings
    ),
    collapse = "\n"
  )
}

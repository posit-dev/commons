# call_metrics compiles a governed query over dictionary metrics, in the
# shape semantic layers converge on: metrics x dimensions x filters, plus
# simple column predicates. Names are passed as strings and validated at
# call time, so nothing depends on lazy board sources being probed before
# tool registration.
call_metrics_impl <- function(
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
  defs <- registry_defs(registry, label)

  metric_defs <- resolve_pool_names(metrics, defs, role = "metric")
  tables <- unique(metric_defs$table)
  if (length(tables) > 1) {
    cli::cli_abort(
      c(
        "Metrics in one query must share a table; these span {.val {tables}}.",
        i = "Query them separately and combine the results with run_r."
      )
    )
  }
  on_table <- defs[defs$table == tables, ]
  columns <- names(source$dictionary$tables[[tables]]$columns)
  con <- source$con
  id <- DBI::dbQuoteIdentifier(con, source$table_ids[[tables]])

  dim_names <- strip_token_braces(dimensions %||% character())
  dims <- vapply(
    rlang::set_names(dim_names),
    function(name) dimension_sql(name, on_table, columns, con),
    character(1)
  )
  filter_defs <- resolve_pool_names(filters, on_table, role = "filter")
  conditions <- c(
    sprintf("(%s)", filter_defs$expanded),
    vapply(
      normalize_where(where),
      function(triple) compile_where_triple(triple, columns, con),
      character(1)
    )
  )

  select <- c(
    sprintf("%s AS %s", dims, DBI::dbQuoteIdentifier(con, names(dims))),
    sprintf(
      "(%s) AS %s",
      metric_defs$expanded,
      DBI::dbQuoteIdentifier(con, metric_defs$name)
    )
  )
  sql <- sprintf("SELECT %s FROM %s", paste(select, collapse = ", "), id)
  if (length(conditions)) {
    sql <- sprintf("%s WHERE %s", sql, paste(conditions, collapse = " AND "))
  }
  if (length(dims)) {
    sql <- sprintf("%s GROUP BY %s", sql, paste(dims, collapse = ", "))
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

# Unvalidated rows (lazy board sources) count: their role resolves at first
# call, and registering the tool can't wait for a probe that deliberately
# hasn't run.
registry_has_metrics <- function(registry) {
  any(is.na(registry$defs$role) | registry$defs$role == "metric")
}

# The prompt teaches `{{name}}` for SQL, so models sometimes pass the
# braces here too; accept both forms.
strip_token_braces <- function(name) {
  gsub("^\\{\\{\\s*|\\s*\\}\\}$", "", trimws(name))
}

resolve_pool_names <- function(names, defs, role) {
  out <- defs[0, ]
  for (name in strip_token_braces(names %||% character())) {
    out <- rbind(out, resolve_pool_name(name, defs, role))
  }
  out
}

resolve_pool_name <- function(name, defs, role) {
  named <- defs[defs$name == name, ]
  matched <- named[which(named$role == role), ]
  if (nrow(matched)) {
    return(matched[1, ])
  }
  if (nrow(named)) {
    cli::cli_abort(
      "{.val {name}} is a {named$role[[1]]}, not a {role}; apply it as
       {.code {{{{{name}}}}}} in SQL instead."
    )
  }
  available <- defs$name[which(defs$role == role)]
  cli::cli_abort(
    c(
      "No governed {role} is named {.val {name}}.",
      i = "Available {role}s: {.val {available}}."
    )
  )
}

dimension_sql <- function(name, defs, columns, con) {
  named <- defs[defs$name == name, ]
  if (nrow(named)) {
    if (!identical(named$role[[1]], "dimension")) {
      cli::cli_abort(
        "{.val {name}} is a {named$role[[1]]} and can't be grouped by."
      )
    }
    return(sprintf("(%s)", named$expanded[[1]]))
  }
  if (name %in% columns) {
    return(as.character(DBI::dbQuoteIdentifier(con, name)))
  }
  dimensions <- defs$name[which(defs$role == "dimension")]
  cli::cli_abort(
    c(
      "No dimension or documented column is named {.val {name}}.",
      i = "Documented columns: {.val {columns}}.",
      i = if (length(dimensions)) "Governed dimensions: {.val {dimensions}}."
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

# One discovery surface over the whole pool: measures and definitions ranked
# together, so the model doesn't have to guess which kind holds its answer.
search_pool_text <- function(
  measures,
  registry,
  query,
  source_names = character()
) {
  defs <- registry_defs(registry)
  if (length(measures) == 0 && nrow(defs) == 0) {
    return("The semantic layer is empty.")
  }

  blank_na <- function(x) ifelse(is.na(x), "", x)
  catalog <- c(
    vapply(
      measures,
      function(td) paste(tool_name(td), tool_description(td)),
      character(1)
    ),
    paste(
      defs$name,
      defs$table,
      blank_na(defs$role),
      blank_na(defs$description),
      blank_na(defs$details)
    )
  )

  hits <- lexical_rank(query, catalog, n = 5)
  if (length(hits) == 0) {
    return(sprintf(
      "Nothing in the semantic layer matches \"%s\". Consider writing a SQL query.",
      query
    ))
  }
  blocks <- vapply(
    hits,
    function(hit) {
      if (hit <= length(measures)) {
        measure_schema_text(measures[[hit]], source_names = source_names)
      } else {
        definition_pool_text(defs[hit - length(measures), ], defs)
      }
    },
    character(1)
  )
  paste(blocks, collapse = "\n\n")
}

definition_pool_text <- function(def, defs) {
  role <- if (is.na(def$role)) "expression" else def$role
  invoke <- switch(
    role,
    filter = sprintf(
      "Apply in run_sql (e.g. `WHERE {{%s}}`) or as a call_metrics filter.",
      def$name
    ),
    metric = sprintf(
      "Query with call_metrics (metrics = [\"%s\"]) or in run_sql as `SELECT {{%s}} AS %s`.",
      def$name,
      def$name,
      def$name
    ),
    sprintf(
      "Use in run_sql SELECT or GROUP BY as `{{%s}}`, or as a call_metrics dimension.",
      def$name
    )
  )

  siblings <- NULL
  if (identical(role, "metric")) {
    same_table <- defs[defs$table == def$table & defs$name != def$name, ]
    if (nrow(same_table)) {
      items <- sprintf(
        "{{%s}} (%s)",
        same_table$name,
        ifelse(is.na(same_table$role), "expression", same_table$role)
      )
      siblings <- sprintf(
        "Filters and dimensions on this table: %s.",
        paste(items, collapse = ", ")
      )
    }
  }

  paste(
    c(
      sprintf(
        "### {{%s}} --- %s on table `%s`\n%s",
        def$name,
        role,
        def$table,
        prose_detail(def$description, def$details)
      ),
      invoke,
      siblings
    ),
    collapse = "\n"
  )
}

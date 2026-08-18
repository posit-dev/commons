# call_metrics compiles a governed query over dictionary metrics, in the
# shape semantic layers converge on: metrics x dimensions x filters, plus
# simple column predicates. Names are passed as strings and validated at
# call time.
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
  defs <- registry_defs(registry, label)

  metric_defs <- resolve_pool_names(metrics, defs, kind = "metric")
  if (any(metric_defs$mixed_grain)) {
    cli::cli_abort(
      "Mixed-grain metric{?s} {.val {metric_defs$name[metric_defs$mixed_grain]}} cannot be queried by {.fn call_metrics}; use the definition in {.fn run_sql}."
    )
  }
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
  filter_defs <- resolve_pool_names(filters, on_table, kind = "filter")
  if (any(filter_defs$mixed_grain)) {
    cli::cli_abort(
      "Mixed-grain filter{?s} {.val {filter_defs$name[filter_defs$mixed_grain]}} cannot be applied by {.fn call_metrics}; use the definition in {.fn run_sql}."
    )
  }
  conditions <- c(
    sprintf("(%s)", filter_defs$sql),
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
      metric_defs$sql,
      DBI::dbQuoteIdentifier(con, metric_defs$name)
    )
  )
  sql <- sprintf(
    "SELECT %s FROM %s",
    paste(select, collapse = ", "),
    id
  )
  if (length(conditions)) {
    sql <- sprintf("%s WHERE %s", sql, paste(conditions, collapse = " AND "))
  }
  if (length(dims)) {
    sql <- sprintf("%s GROUP BY %s", sql, paste(dims, collapse = ", "))
  } else {
    # Force a global group so constants remain scalar when no rows remain.
    sql <- sprintf("%s HAVING COUNT(*) >= 0", sql)
  }

  result <- source_query(source, sql)
  advert <- register_handle(handles, result)
  dimension_defs <- on_table[
    match(dim_names, on_table$name, nomatch = 0L),
  ]
  applied <- rbind(metric_defs, dimension_defs, filter_defs)
  applied <- applied[!duplicated(applied[c("name", "table", "source")]), ]
  note <- applied_definitions_text(applied)
  args <- drop_nulls(list(
    metrics = metrics,
    dimensions = dimensions,
    filters = filters
  ))
  tool_result(
    paste(c(df_to_markdown(result), note, advert), collapse = "\n\n"),
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

registry_has_metrics <- function(registry) {
  any(registry$defs$kind == "metric")
}

# The prompt teaches `{{name}}` for SQL, so models sometimes pass the
# braces here too; accept both forms.
strip_token_braces <- function(name) {
  gsub("^\\{\\{\\s*|\\s*\\}\\}$", "", trimws(name))
}

resolve_pool_names <- function(names, defs, kind) {
  out <- defs[0, ]
  for (name in strip_token_braces(names %||% character())) {
    out <- rbind(out, resolve_pool_name(name, defs, kind))
  }
  out
}

resolve_pool_name <- function(name, defs, kind) {
  named <- pool_name_candidates(name, defs)
  matched <- named[which(named$kind == kind), ]
  if (nrow(matched) == 1L) {
    return(matched[1, ])
  }
  if (nrow(matched) > 1L) {
    qualified <- sprintf("{{%s::%s}}", matched$table, matched$name)
    cli::cli_abort(
      c(
        "Governed {kind} name {.val {name}} is ambiguous.",
        i = "Qualify it as {.or {.code {qualified}}}."
      )
    )
  }
  if (nrow(named)) {
    cli::cli_abort(
      "{.val {name}} is a {named$kind[[1]]}, not a {kind}; apply it as
       {.code {{{{{name}}}}}} in SQL instead."
    )
  }
  available <- defs$name[which(defs$kind == kind)]
  cli::cli_abort(
    c(
      "No governed {kind} is named {.val {name}}.",
      i = "Available {kind}s: {.val {available}}."
    )
  )
}

pool_name_candidates <- function(name, defs) {
  separator <- regexpr("::", name, fixed = TRUE)[[1]]
  if (separator > 0L) {
    table <- substr(name, 1L, separator - 1L)
    definition <- substr(name, separator + 2L, nchar(name))
    return(defs[defs$table == table & defs$name == definition, ])
  }
  defs[defs$name == name, ]
}

dimension_sql <- function(name, defs, columns, con) {
  named <- defs[defs$name == name, ]
  if (nrow(named)) {
    if (!named$kind[[1]] %in% c("derived", "filter")) {
      cli::cli_abort(
        "{.val {name}} is a {named$kind[[1]]} and can't be grouped by."
      )
    }
    if (named$mixed_grain[[1]]) {
      cli::cli_abort(
        "Mixed-grain definition {.val {name}} cannot be grouped by with {.fn call_metrics}; use it in {.fn run_sql}."
      )
    }
    return(sprintf("(%s)", named$sql[[1]]))
  }
  if (name %in% columns) {
    return(as.character(DBI::dbQuoteIdentifier(con, name)))
  }
  dimensions <- defs$name[
    which(defs$kind %in% c("derived", "filter") & !defs$mixed_grain)
  ]
  cli::cli_abort(
    c(
      "No dimension or documented column is named {.val {name}}.",
      i = "Documented columns: {.val {columns}}.",
      i = if (length(dimensions)) {
        "Governed row definitions: {.val {dimensions}}."
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
      defs$kind,
      blank_na(defs$label),
      blank_na(defs$description),
      blank_na(defs$details),
      blank_na(defs$expression)
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
  kind <- def$kind
  invoke <- switch(
    kind,
    filter = sprintf(
      "Apply in run_sql (e.g. `WHERE {{%s}}`) or as a call_metrics filter or dimension.",
      def$name
    ),
    metric = sprintf(
      "Query with call_metrics (metrics = [\"%s\"]) or in run_sql as `SELECT {{%s}} AS value`.",
      def$name,
      def$name
    ),
    sprintf(
      "Use in run_sql SELECT or GROUP BY as `{{%s}}`, or as a call_metrics dimension.",
      def$name
    )
  )

  siblings <- NULL
  if (identical(kind, "metric")) {
    same_table <- defs[
      defs$table == def$table &
        defs$name != def$name &
        defs$kind %in% c("filter", "derived") &
        !defs$mixed_grain,
    ]
    if (nrow(same_table)) {
      items <- sprintf(
        "{{%s}} (%s)",
        same_table$name,
        same_table$kind
      )
      siblings <- sprintf(
        "Filters and derived definitions on this table: %s.",
        paste(items, collapse = ", ")
      )
    }
  }

  paste(
    c(
      sprintf(
        "### {{%s}} --- %s on table `%s`\n%s",
        def$name,
        kind,
        def$table,
        prose_detail(def$description, def$details)
      ),
      sprintf("Expression: `%s`.", flatten_inline(def$expression)),
      sprintf(
        "Selected %s: `(%s)`.",
        def$target,
        flatten_inline(def$sql)
      ),
      if (length(def$notes[[1]])) {
        sprintf(
          "Translation notes: %s",
          paste(def$notes[[1]], collapse = " ")
        )
      },
      invoke,
      siblings
    ),
    collapse = "\n"
  )
}

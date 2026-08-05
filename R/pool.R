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
  source_name = NULL,
  arguments = "{}"
) {
  source <- resolve_sql_source(sources, source_name)
  label <- source_name %||% rlang::names2(sources)[[1]]
  defs <- registry_defs(registry, label)

  metric_defs <- resolve_pool_names(metrics, defs, role = "metric")
  executions <- unique(metric_defs$execution)
  if (length(executions) != 1) {
    cli::cli_abort("Metrics in one query must use the same native execution path.")
  }
  if (!identical(executions, "data_dictionary")) {
    return(call_native_metrics(
      executions,
      metric_defs,
      defs,
      source,
      handles,
      metrics,
      dimensions,
      filters,
      where,
      arguments,
      source_name
    ))
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
  columns <- names(source_runtime_dictionary(source)$tables[[tables]]$columns)
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
      "Ran a trusted calculation: %s%s",
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

native_metric_query <- function(source, model_id, sql) {
  result <- tryCatch(source_query(source, sql), error = function(err) err)
  if (inherits(result, "condition")) {
    message <- conditionMessage(result)
    state <- if (grepl(
      "permission|not authorized|insufficient privilege|access denied",
      message,
      ignore.case = TRUE
    )) {
      "visible_only"
    } else {
      "unknown"
    }
    catalog_model_access(source, model_id, state, message)
    rlang::cnd_signal(result)
  }
  catalog_model_access(source, model_id, "queryable", "native query succeeded")
  result
}

catalog_model_access <- function(source, model_id, state, evidence) {
  model <- source$provider$catalog$models[[model_id]]
  model$access <- new_catalog_access(state, evidence)
  source$provider$catalog$models[[model_id]] <- model
  for (relation_id in model$exposed) {
    relation <- source$provider$catalog$relations[[relation_id]]
    relation$access <- new_catalog_access(state, evidence)
    source$provider$catalog$relations[[relation_id]] <- relation
  }
  invisible(source)
}

call_native_metrics <- function(
  execution,
  metric_defs,
  defs,
  source,
  handles,
  metrics,
  dimensions,
  filters,
  where,
  arguments,
  source_name
) {
  model_ids <- unique(metric_defs$model_id)
  if (length(model_ids) != 1) {
    cli::cli_abort("Metrics in one query must belong to the same semantic model.")
  }
  on_model <- defs[defs$model_id == model_ids, ]
  sql <- switch(
    execution,
    snowflake_semantic_view = snowflake_metric_sql(
      source,
      model_ids,
      metric_defs,
      on_model,
      dimensions,
      filters,
      where,
      arguments
    ),
    databricks_metric_view = databricks_metric_sql(
      source,
      model_ids,
      metric_defs,
      on_model,
      dimensions,
      filters,
      where,
      arguments
    ),
    cli::cli_abort("Unsupported native metric execution kind {.val {execution}}.")
  )
  result <- native_metric_query(source, model_ids, sql)
  metric_tool_result(
    result,
    sql,
    handles,
    metrics,
    dimensions,
    filters,
    source_name
  )
}

snowflake_metric_sql <- function(
  source,
  model_id,
  metrics,
  defs,
  dimensions,
  filters,
  where,
  arguments = "{}"
) {
  if (!identical(arguments, "{}") && length(parse_json_args(arguments))) {
    cli::cli_abort("This Snowflake semantic view does not expose runtime parameters.")
  }
  con <- source$con
  model <- source$provider$catalog$models[[model_id]]
  object <- source_path_id(model$execution$object)
  dimension_defs <- resolve_pool_names(
    dimensions,
    defs,
    role = "dimension"
  )
  filter_defs <- resolve_pool_names(filters, defs, role = "filter")
  parts <- c(
    as.character(DBI::dbQuoteIdentifier(con, object)),
    if (nrow(dimension_defs)) {
      paste(
        "DIMENSIONS",
        paste(native_definition_references(dimension_defs, con), collapse = ", ")
      )
    },
    paste(
      "METRICS",
      paste(native_definition_references(metrics, con), collapse = ", ")
    )
  )
  conditions <- c(
    native_definition_references(filter_defs, con),
    native_where_conditions(where, defs, con)
  )
  if (length(conditions)) {
    parts <- c(parts, paste("WHERE", paste(conditions, collapse = " AND ")))
  }
  paste0("SELECT * FROM SEMANTIC_VIEW(\n  ", paste(parts, collapse = "\n  "), "\n)")
}

databricks_metric_sql <- function(
  source,
  model_id,
  metrics,
  defs,
  dimensions,
  filters,
  where,
  arguments = "{}"
) {
  if (length(filters)) {
    cli::cli_abort("Databricks metric views do not expose named runtime filters.")
  }
  con <- source$con
  model <- source$provider$catalog$models[[model_id]]
  object <- source_path_id(model$execution$object)
  object_sql <- databricks_metric_source(
    object,
    model$execution$parameters,
    arguments,
    con
  )
  dimension_defs <- resolve_pool_names(
    dimensions,
    defs,
    role = "dimension"
  )
  dimension_names <- vapply(
    dimension_defs$name,
    function(name) as.character(DBI::dbQuoteIdentifier(con, name)),
    character(1)
  )
  metric_sql <- vapply(metrics$name, function(name) {
    quoted <- DBI::dbQuoteIdentifier(con, name)
    sprintf("MEASURE(%s) AS %s", quoted, quoted)
  }, character(1))
  sql <- paste(
    "SELECT",
    paste(c(dimension_names, metric_sql), collapse = ", "),
    "FROM",
    object_sql
  )
  conditions <- native_where_conditions(where, defs, con)
  if (length(conditions)) {
    sql <- paste(sql, "WHERE", paste(conditions, collapse = " AND "))
  }
  if (length(dimension_names)) {
    sql <- paste(sql, "GROUP BY", paste(dimension_names, collapse = ", "))
  }
  sql
}

databricks_metric_source <- function(object, parameters, arguments, con) {
  quoted <- as.character(DBI::dbQuoteIdentifier(con, object))
  values <- parse_json_args(arguments %||% "{}")
  if (length(parameters) == 0) {
    if (length(values)) {
      cli::cli_abort("This metric view does not accept parameters.")
    }
    return(quoted)
  }
  parameter_names <- vapply(parameters, `[[`, character(1), "name")
  extra <- setdiff(names(values), parameter_names)
  required <- parameter_names[!vapply(
    parameters,
    function(parameter) "default" %in% names(parameter),
    logical(1)
  )]
  missing <- setdiff(required, names(values))
  if (length(extra) || length(missing)) {
    cli::cli_abort(c(
      "Metric-view parameters do not match the model.",
      "x" = if (length(extra)) "Unknown parameters: {.val {extra}}.",
      "x" = if (length(missing)) "Missing parameters: {.val {missing}}."
    ))
  }
  supplied <- intersect(parameter_names, names(values))
  if (length(supplied) == 0) {
    return(quoted)
  }
  sql <- vapply(supplied, function(name) {
    parameter <- parameters[[match(name, parameter_names)]]
    paste(
      DBI::dbQuoteIdentifier(con, name),
      "=>",
      databricks_parameter_value(values[[name]], parameter$data_type, con)
    )
  }, character(1))
  paste0(quoted, "(", paste(sql, collapse = ", "), ")")
}

databricks_parameter_value <- function(value, type, con) {
  if (length(value) != 1 || is.null(value) || is.na(value)) {
    cli::cli_abort("Metric-view parameter values must be non-missing scalars.")
  }
  normalized <- tolower(trimws(type))
  if (grepl("^(tinyint|smallint|int|integer|bigint)$", normalized)) {
    if (!is.numeric(value) || value != as.integer(value)) {
      cli::cli_abort("Metric-view parameter type {.val {type}} requires an integer.")
    }
    return(as.character(as.integer(value)))
  }
  if (grepl("^(float|double|real|decimal|decimal\\([0-9]+,[0-9]+\\))$", normalized)) {
    if (!is.numeric(value) || !is.finite(value)) {
      cli::cli_abort("Metric-view parameter type {.val {type}} requires a number.")
    }
    return(as.character(value))
  }
  if (normalized %in% c("boolean", "bool")) {
    if (!is.logical(value)) {
      cli::cli_abort("Metric-view parameter type {.val {type}} requires true or false.")
    }
    return(if (value) "TRUE" else "FALSE")
  }
  if (normalized == "date") {
    if (!is.character(value) || is.na(as.Date(value))) {
      cli::cli_abort("Metric-view date parameters require an ISO date string.")
    }
    return(paste0("CAST(", DBI::dbQuoteString(con, value), " AS DATE)"))
  }
  if (normalized %in% c("timestamp", "timestamp_ntz", "datetime")) {
    if (!is.character(value) || !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}", value)) {
      cli::cli_abort("Metric-view timestamp parameters require an ISO timestamp string.")
    }
    cast <- if (normalized == "timestamp_ntz") "TIMESTAMP_NTZ" else "TIMESTAMP"
    return(paste0("CAST(", DBI::dbQuoteString(con, value), " AS ", cast, ")"))
  }
  if (grepl("^(string|varchar|char)(\\([0-9]+\\))?$", normalized)) {
    if (!is.character(value)) {
      cli::cli_abort("Metric-view parameter type {.val {type}} requires a string.")
    }
    return(as.character(DBI::dbQuoteString(con, value)))
  }
  cli::cli_abort("Unsupported metric-view parameter type {.val {type}}.")
}

native_definition_references <- function(defs, con) {
  vapply(seq_len(nrow(defs)), function(i) {
    parent <- defs$native_parent[[i]]
    if (is.na(parent) || !nzchar(parent)) {
      return(as.character(DBI::dbQuoteIdentifier(con, defs$name[[i]])))
    }
    as.character(DBI::dbQuoteIdentifier(
      con,
      DBI::Id(schema = parent, table = defs$name[[i]])
    ))
  }, character(1))
}

native_where_conditions <- function(where, defs, con) {
  vapply(normalize_where(where), function(triple) {
    for (field in c("column", "op", "value")) {
      value <- triple[[field]]
      if (length(value) != 1 || is.na(value) || !nzchar(as.character(value))) {
        cli::cli_abort("Each {.arg where} entry needs {.field column}, {.field op}, and {.field value}.")
      }
      triple[[field]] <- as.character(value)
    }
    if (!triple$op %in% where_ops) {
      cli::cli_abort("{.arg where} operator must be one of {.val {where_ops}}.")
    }
    dimension <- resolve_pool_name(triple$column, defs, "dimension")
    reference <- native_definition_references(dimension, con)
    value <- if (grepl("^-?[0-9]+(\\.[0-9]+)?$", triple$value)) {
      triple$value
    } else {
      as.character(DBI::dbQuoteString(con, triple$value))
    }
    sprintf("(%s %s %s)", reference, triple$op, value)
  }, character(1))
}

source_path_id <- function(path) {
  do.call(DBI::Id, as.list(stats::setNames(path$components, path$roles)))
}

metric_tool_result <- function(
  result,
  sql,
  handles,
  metrics,
  dimensions,
  filters,
  source_name
) {
  advert <- register_handle(handles, result)
  args <- drop_nulls(list(
    metrics = metrics,
    dimensions = dimensions,
    filters = filters
  ))
  tool_result(
    paste(c(df_to_markdown(result), advert), collapse = "\n\n"),
    title = sprintf(
      "Ran a trusted calculation: %s%s",
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
  any(registry$defs$role == "metric")
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
  source_names = character(),
  calculations = list()
) {
  defs <- registry_defs(registry)
  if (length(measures) == 0 && nrow(defs) == 0 && length(calculations) == 0) {
    return("The semantic layer is empty.")
  }

  blank_na <- function(x) ifelse(is.na(x), "", x)
  catalog <- c(
    vapply(
      measures,
      function(td) paste(tool_name(td), tool_description(td)),
      character(1)
    ),
    vapply(calculations, function(entry) {
      calculation <- entry$calculation
      paste(
        calculation$name,
        calculation$description,
        names(calculation$arguments),
        entry$source_name
      )
    }, character(1)),
    paste(
      defs$name,
      defs$table,
      defs$role,
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
      } else if (hit <= length(measures) + length(calculations)) {
        calculation_pool_text(
          calculations[[hit - length(measures)]],
          show_source = length(source_names) > 1
        )
      } else {
        definition_pool_text(
          defs[hit - length(measures) - length(calculations), ],
          defs
        )
      }
    },
    character(1)
  )
  paste(blocks, collapse = "\n\n")
}

definition_pool_text <- function(def, defs) {
  role <- def$role
  invoke <- if (!identical(def$execution[[1]], "data_dictionary")) {
    switch(
      role,
      metric = sprintf(
        "Query with call_metrics (metrics = [\"%s\"]).",
        def$name
      ),
      filter = sprintf("Use as a call_metrics filter: %s.", def$name),
      sprintf("Use as a call_metrics dimension: %s.", def$name)
    )
  } else {
    switch(
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
  }

  siblings <- NULL
  if (identical(role, "metric")) {
    same_table <- defs[defs$table == def$table & defs$name != def$name, ]
    if (nrow(same_table)) {
      items <- sprintf(
        "{{%s}} (%s)",
        same_table$name,
        same_table$role
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

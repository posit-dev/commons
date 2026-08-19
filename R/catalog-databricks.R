is_databricks_connection <- function(con) {
  info <- tryCatch(DBI::dbGetInfo(con), error = function(err) NULL)
  labels <- c(info$drivername, info$sourcename)
  labels <- labels[!is.na(labels)]
  length(labels) > 0L && any(grepl("databricks", labels, ignore.case = TRUE))
}

databricks_table_registry <- function(
  con,
  tables = NULL,
  call = rlang::caller_env()
) {
  registry <- catalog_table_registry(
    con,
    tables,
    current_namespace = databricks_current_namespace,
    id_type = databricks_id_type,
    exact_relation = databricks_exact_relation,
    list_relations = databricks_list_relations,
    call = call
  )
  semantic_views <- Filter(
    function(relation) identical(relation$kind, "metric_view"),
    registry$relations
  )
  models <- lapply(
    semantic_views,
    databricks_read_semantic_model,
    con = con,
    call = call
  )
  unsupported <- vapply(
    models,
    inherits,
    logical(1),
    "commons_unsupported_databricks_metric_view"
  )
  exact_unsupported <- intersect(
    names(models)[unsupported],
    registry$validate$labels
  )
  if (length(exact_unsupported)) {
    databricks_abort_unsupported_metric_views(
      models[exact_unsupported],
      call = call
    )
  }
  if (any(unsupported)) {
    databricks_warn_unsupported_metric_views(models[unsupported])
  }
  registry <- catalog_exclude_relations(registry, names(semantic_views))
  registry$semantic_models <- models[!unsupported]
  registry
}

databricks_abort_unsupported_metric_views <- function(models, call) {
  problems <- vapply(models, `[[`, character(1), "reason")
  cli::cli_abort(
    c(
      "Some selected Databricks metric views are not supported:",
      stats::setNames(paste0(names(problems), ": ", problems), "*")
    ),
    call = call
  )
}

databricks_warn_unsupported_metric_views <- function(models) {
  problems <- vapply(models, `[[`, character(1), "reason")
  cli::cli_warn(c(
    "Skipping unsupported Databricks metric views:",
    stats::setNames(paste0(names(problems), ": ", problems), "*")
  ))
}

databricks_current_namespace <- function(con, call = rlang::caller_env()) {
  row <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT CURRENT_CATALOG() AS catalog,",
        "CURRENT_SCHEMA() AS schema"
      )
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to read the current Databricks namespace.",
        parent = err,
        call = call
      )
    }
  )
  names(row) <- tolower(names(row))
  if (nrow(row) != 1L || !all(c("catalog", "schema") %in% names(row))) {
    cli::cli_abort(
      "Databricks returned an invalid current namespace.",
      call = call
    )
  }
  values <- unlist(row[1, c("catalog", "schema")], use.names = TRUE)
  if (
    length(values) != 2L ||
      any(is.na(values)) ||
      any(!nzchar(values))
  ) {
    cli::cli_abort(
      c(
        "The Databricks connection has no current catalog and schema.",
        "i" = "Set both on the connection or supply {.arg tables} as a {.cls DBI::Id}."
      ),
      call = call
    )
  }
  DBI::Id(catalog = values[["catalog"]], schema = values[["schema"]])
}

databricks_list_relations <- function(
  con,
  namespace,
  call = rlang::caller_env()
) {
  namespace <- databricks_complete_namespace(con, namespace, call = call)
  components <- namespace@name
  # `system.information_schema` does not expose legacy hive_metastore tables.
  if (identical(tolower(components[["catalog"]]), "hive_metastore")) {
    return(databricks_list_hive_relations(con, namespace, call = call))
  }

  databricks_list_unity_relations(con, namespace, call = call)
}

databricks_list_unity_relations <- function(
  con,
  prefix,
  call = rlang::caller_env()
) {
  components <- prefix@name

  predicates <- c(
    paste0(
      "table_catalog = ",
      DBI::dbQuoteString(con, components[["catalog"]])
    ),
    "table_schema <> 'information_schema'",
    if ("schema" %in% names(components)) {
      paste0(
        "table_schema = ",
        DBI::dbQuoteString(con, components[["schema"]])
      )
    },
    if ("table" %in% names(components)) {
      paste0(
        "table_name = ",
        DBI::dbQuoteString(con, components[["table"]])
      )
    }
  )
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT table_catalog, table_schema, table_name, table_type, comment",
        "FROM system.information_schema.tables WHERE",
        paste(predicates, collapse = " AND "),
        "ORDER BY table_catalog, table_schema, table_name"
      )
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to list relations in the selected Databricks namespace.",
        parent = err,
        call = call
      )
    }
  )
  names(rows) <- tolower(names(rows))
  semantic_candidates <- grepl(
    "view|metric",
    rows$table_type,
    ignore.case = TRUE
  )
  candidate_schemas <- unique(rows$table_schema[semantic_candidates])
  object_types <- databricks_odbc_object_types(
    con,
    components[["catalog"]],
    candidate_schemas
  )
  databricks_relations_from_information_schema(rows, object_types)
}

databricks_exact_relation <- function(con, id, call = rlang::caller_env()) {
  complete <- databricks_complete_relation(con, id, call = call)
  components <- complete@name
  namespace <- DBI::Id(
    catalog = components[["catalog"]],
    schema = components[["schema"]]
  )
  relations <- if (
    identical(tolower(components[["catalog"]]), "hive_metastore")
  ) {
    databricks_list_hive_relations(con, namespace, call = call)
  } else {
    databricks_list_unity_relations(con, complete, call = call)
  }
  catalog_match_exact_relation(relations, id)
}

databricks_relations_from_information_schema <- function(
  rows,
  object_types = character()
) {
  names(rows) <- tolower(names(rows))
  lapply(seq_len(nrow(rows)), function(i) {
    description <- rows$comment[[i]]
    if (is.na(description) || !nzchar(description)) {
      description <- NULL
    }
    key <- databricks_object_key(
      rows$table_schema[[i]],
      rows$table_name[[i]]
    )
    object_type <- unname(object_types[key])
    if (length(object_type) == 0L || is.na(object_type)) {
      object_type <- rows$table_type[[i]]
    }
    kind <- if (grepl("metric", object_type, ignore.case = TRUE)) {
      "metric_view"
    } else if (grepl("view", object_type, ignore.case = TRUE)) {
      "view"
    } else {
      "table"
    }
    list(
      id = DBI::Id(
        catalog = rows$table_catalog[[i]],
        schema = rows$table_schema[[i]],
        table = rows$table_name[[i]]
      ),
      kind = kind,
      description = description
    )
  })
}

databricks_odbc_object_types <- function(con, catalog, schemas) {
  if (
    !requireNamespace("odbc", quietly = TRUE) ||
      !inherits(con, "OdbcConnection") ||
      length(schemas) == 0L
  ) {
    return(character())
  }
  types <- lapply(unique(schemas), function(schema) {
    rows <- tryCatch(
      odbc::odbcListObjects(con, catalog = catalog, schema = schema),
      error = function(err) NULL
    )
    if (
      is.null(rows) ||
        nrow(rows) == 0L
    ) {
      return(character())
    }
    names(rows) <- tolower(names(rows))
    if (!all(c("name", "type") %in% names(rows))) {
      return(character())
    }
    stats::setNames(
      as.character(rows$type),
      databricks_object_key(schema, rows$name)
    )
  })
  unlist(types, use.names = TRUE)
}

databricks_object_key <- function(schema, table) {
  paste(schema, table, sep = "\034")
}

databricks_list_hive_relations <- function(
  con,
  namespace,
  call = rlang::caller_env()
) {
  components <- namespace@name
  if (!"schema" %in% names(components)) {
    cli::cli_abort(
      "Selecting {.val hive_metastore} requires a schema-level {.cls DBI::Id}.",
      call = call
    )
  }
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste("SHOW TABLES IN", DBI::dbQuoteIdentifier(con, namespace))
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to list relations in the selected hive_metastore schema.",
        parent = err,
        call = call
      )
    }
  )
  names(rows) <- tolower(names(rows))
  lapply(rows$tablename, function(table) {
    list(
      id = DBI::Id(
        catalog = components[["catalog"]],
        schema = components[["schema"]],
        table = table
      ),
      kind = NULL,
      description = NULL
    )
  })
}

databricks_read_semantic_model <- function(
  view,
  con,
  call = rlang::caller_env()
) {
  rlang::check_installed("yaml", call = call)
  id <- databricks_complete_relation(con, view$id, call = call)
  label <- table_id_label(id, call = call)
  metadata <- NULL
  text <- databricks_view_definition(con, id)
  if (is.null(text)) {
    metadata <- databricks_metric_view_metadata(con, id)
    text <- metadata$view_text %||% metadata$viewText
  }
  if (is.null(text)) {
    cli::cli_abort(
      "Failed to read Databricks metric view {.val {label}}.",
      call = call
    )
  }
  specification <- tryCatch(
    yaml::yaml.load(text),
    error = function(err) {
      cli::cli_abort(
        "Databricks metric view {.val {label}} returned invalid YAML.",
        parent = err,
        call = call
      )
    }
  )
  if (
    !is.list(specification) ||
      is.null(specification$version) ||
      (
        is.null(specification$fields) &&
          is.null(specification$dimensions) &&
          is.null(specification$measures)
      )
  ) {
    cli::cli_abort(
      "Databricks metric view {.val {label}} returned an invalid specification.",
      call = call
    )
  }
  if (length(specification$parameters %||% list())) {
    return(databricks_unsupported_metric_view(
      view$id,
      "parameters are not supported"
    ))
  }
  if (databricks_semantic_has_wildcards(specification)) {
    metadata <- metadata %||% databricks_metric_view_metadata(con, id)
    if (length(metadata$columns %||% list()) == 0L) {
      return(databricks_unsupported_metric_view(
        view$id,
        "wildcard members could not be expanded from column metadata"
      ))
    }
  }
  databricks_semantic_model_from_spec(
    view$id,
    specification,
    description = view$description,
    columns = metadata$columns %||% list()
  )
}

databricks_metric_view_metadata <- function(con, id) {
  text <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "DESCRIBE TABLE EXTENDED",
        DBI::dbQuoteIdentifier(con, id),
        "AS JSON"
      )
    )[[1]][[1]],
    error = function(err) NULL
  )
  if (is.null(text)) {
    return(list())
  }
  tryCatch(
    jsonlite::fromJSON(text, simplifyVector = FALSE),
    error = function(err) list()
  )
}

databricks_unsupported_metric_view <- function(id, reason) {
  structure(
    list(id = id, reason = reason),
    class = "commons_unsupported_databricks_metric_view"
  )
}

databricks_view_definition_max_size <- 200000L
databricks_view_definition_chunk_size <- 900L

databricks_view_definition <- function(con, id) {
  components <- id@name
  predicates <- c(
    paste0("table_catalog = ", DBI::dbQuoteString(con, components[["catalog"]])),
    paste0("table_schema = ", DBI::dbQuoteString(con, components[["schema"]])),
    paste0("table_name = ", DBI::dbQuoteString(con, components[["table"]]))
  )
  where <- paste(predicates, collapse = " AND ")
  length_row <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT length(view_definition) AS definition_length",
        "FROM system.information_schema.views WHERE",
        where
      )
    ),
    error = function(err) NULL
  )
  if (
    is.null(length_row) ||
      nrow(length_row) == 0L ||
      is.na(length_row[[1]][[1]])
  ) {
    return(NULL)
  }
  length <- as.integer(length_row[[1]][[1]])
  if (length > databricks_view_definition_max_size) {
    return(NULL)
  }
  # Stay below the configured ODBC driver's per-column truncation limit.
  starts <- seq.int(
    1L,
    max(1L, length),
    by = databricks_view_definition_chunk_size
  )
  expressions <- sprintf(
    "substring(view_definition, %d, %d) AS chunk_%d",
    starts,
    databricks_view_definition_chunk_size,
    seq_along(starts)
  )
  row <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT",
        paste(expressions, collapse = ", "),
        "FROM system.information_schema.views WHERE",
        where
      )
    ),
    error = function(err) NULL
  )
  if (is.null(row) || nrow(row) == 0L) {
    return(NULL)
  }
  paste(unlist(row[1, ], use.names = FALSE), collapse = "")
}

databricks_semantic_model_from_spec <- function(
  id,
  specification,
  description = NULL,
  columns = list()
) {
  if (length(specification$parameters %||% list())) {
    cli::cli_abort("Parameterized Databricks metric views are not supported.")
  }
  if (
    databricks_semantic_has_wildcards(specification) &&
      length(columns) == 0L
  ) {
    cli::cli_abort(
      "Databricks wildcard members require concrete column metadata."
    )
  }
  dimensions <- c(
    databricks_semantic_members(specification$fields, "dimension"),
    databricks_semantic_members(specification$dimensions, "dimension")
  )
  metrics <- databricks_semantic_members(specification$measures, "metric")
  dimensions <- c(
    dimensions,
    databricks_semantic_wildcard_members(
      columns,
      "dimension",
      dimensions,
      c(specification$fields, specification$dimensions)
    )
  )
  metrics <- c(
    metrics,
    databricks_semantic_wildcard_members(
      columns,
      "metric",
      metrics,
      specification$measures
    )
  )
  new_semantic_model(
    id,
    name = id@name[["table"]],
    description = specification$comment %||% description,
    backend = "databricks_metric_view",
    dimensions = dimensions,
    metrics = metrics
  )
}

databricks_semantic_members <- function(entries, kind) {
  members <- list()
  for (item in semantic_spec_entries(entries)) {
    name <- item$name
    if (!rlang::is_string(name) || !nzchar(name)) {
      next
    }
    members[[length(members) + 1L]] <- new_semantic_member(
      name,
      kind,
      label = item$display_name,
      description = item$comment,
      type = item$data_type,
      synonyms = as.character(unlist(
        item$synonyms %||% character(),
        use.names = FALSE
      ))
    )
  }
  members
}

databricks_semantic_has_wildcards <- function(specification) {
  entries <- c(
    specification$fields,
    specification$dimensions,
    specification$measures
  )
  any(vapply(
    semantic_spec_entries(entries),
    function(item) !rlang::is_string(item$name) || !nzchar(item$name),
    logical(1)
  ))
}

databricks_semantic_wildcard_members <- function(
  columns,
  kind,
  explicit,
  entries
) {
  if (!databricks_semantic_entries_have_wildcard(entries)) {
    return(list())
  }
  is_measure <- vapply(
    columns,
    function(column) isTRUE(column$is_measure),
    logical(1)
  )
  columns <- if (identical(kind, "metric")) {
    columns[is_measure]
  } else {
    columns[!is_measure]
  }
  explicit_names <- vapply(explicit, `[[`, character(1), "name")
  columns <- Filter(function(column) {
    rlang::is_string(column$name) &&
      nzchar(column$name) &&
      !column$name %in% explicit_names
  }, columns)
  lapply(columns, function(column) {
    new_semantic_member(
      column$name,
      kind,
      description = column$comment,
      type = databricks_type_text(column$type)
    )
  })
}

databricks_semantic_entries_have_wildcard <- function(entries) {
  any(vapply(
    semantic_spec_entries(entries),
    function(item) !rlang::is_string(item$name) || !nzchar(item$name),
    logical(1)
  ))
}

databricks_type_text <- function(type) {
  if (rlang::is_string(type)) {
    return(type)
  }
  if (!is.list(type) || !rlang::is_string(type$name)) {
    return(NULL)
  }
  switch(
    type$name,
    decimal = sprintf("decimal(%s,%s)", type$precision, type$scale),
    varchar = sprintf("varchar(%s)", type$length),
    char = sprintf("char(%s)", type$length),
    type$name
  )
}

databricks_semantic_metric_sql <- function(
  model,
  metrics,
  dimensions,
  where,
  members,
  con
) {
  dimension_sql <- databricks_semantic_member_references(dimensions, con)
  metric_sql <- vapply(seq_len(nrow(metrics)), function(i) {
    reference <- DBI::dbQuoteIdentifier(con, metrics$name[[i]])
    sprintf("MEASURE(%s) AS %s", reference, reference)
  }, character(1))
  sql <- paste(
    "SELECT",
    paste(c(dimension_sql, metric_sql), collapse = ", "),
    "FROM",
    DBI::dbQuoteIdentifier(con, model$id)
  )
  conditions <- semantic_where_conditions(
    where,
    members,
    con,
    databricks_semantic_member_references
  )
  if (length(conditions)) {
    sql <- paste(sql, "WHERE", paste(conditions, collapse = " AND "))
  }
  if (length(dimension_sql)) {
    sql <- paste(sql, "GROUP BY", paste(dimension_sql, collapse = ", "))
  }
  sql
}

databricks_semantic_member_references <- function(members, con) {
  vapply(
    members$name,
    function(name) as.character(DBI::dbQuoteIdentifier(con, name)),
    character(1)
  )
}

databricks_describe_relation <- function(con, id, call = rlang::caller_env()) {
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste("DESCRIBE TABLE", DBI::dbQuoteIdentifier(con, id))
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to describe the selected Databricks relation.",
        parent = err,
        call = call
      )
    }
  )
  complete <- databricks_complete_relation(con, id, call = call)
  nullable <- databricks_column_nullability(con, complete, call = call)
  databricks_columns_from_describe(rows, nullable)
}

databricks_column_nullability <- function(
  con,
  id,
  call = rlang::caller_env()
) {
  components <- id@name
  if (identical(tolower(components[["catalog"]]), "hive_metastore")) {
    return(logical())
  }
  predicates <- c(
    paste0("table_catalog = ", DBI::dbQuoteString(con, components[["catalog"]])),
    paste0("table_schema = ", DBI::dbQuoteString(con, components[["schema"]])),
    paste0("table_name = ", DBI::dbQuoteString(con, components[["table"]]))
  )
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT column_name, is_nullable",
        "FROM system.information_schema.columns WHERE",
        paste(predicates, collapse = " AND ")
      )
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to read Databricks column nullability.",
        parent = err,
        call = call
      )
    }
  )
  names(rows) <- tolower(names(rows))
  nullable <- rep(NA, nrow(rows))
  is_nullable <- toupper(rows$is_nullable)
  nullable[is_nullable %in% "YES"] <- TRUE
  nullable[is_nullable %in% "NO"] <- FALSE
  stats::setNames(nullable, rows$column_name)
}

databricks_columns_from_describe <- function(rows, nullable = logical()) {
  names(rows) <- tolower(names(rows))
  metadata <- which(startsWith(rows$col_name, "#"))
  if (length(metadata)) {
    rows <- rows[seq_len(metadata[[1]] - 1L), , drop = FALSE]
  }
  rows <- rows[
    !is.na(rows$col_name) &
      nzchar(rows$col_name),
    ,
    drop = FALSE
  ]
  description <- rows$comment
  description[is.na(description) | !nzchar(description)] <- NA_character_
  column_nullable <- unname(nullable[rows$col_name])
  if (length(nullable) == 0L) {
    column_nullable <- rep(NA, nrow(rows))
  }
  data.frame(
    column = rows$col_name,
    type = rows$data_type,
    nullable = column_nullable,
    description = description,
    row.names = NULL
  )
}

databricks_complete_namespace <- function(
  con,
  id,
  call = rlang::caller_env()
) {
  components <- id@name
  if (!"catalog" %in% names(components)) {
    current <- databricks_current_namespace(con, call = call)@name
    catalog <- current[["catalog"]]
  } else {
    catalog <- components[["catalog"]]
  }
  if ("schema" %in% names(components)) {
    return(DBI::Id(catalog = catalog, schema = components[["schema"]]))
  }
  DBI::Id(catalog = catalog)
}

databricks_complete_relation <- function(
  con,
  id,
  call = rlang::caller_env()
) {
  components <- id@name
  if (!all(c("catalog", "schema") %in% names(components))) {
    current <- databricks_current_namespace(con, call = call)@name
  } else {
    current <- NULL
  }
  DBI::Id(
    catalog = if ("catalog" %in% names(components)) {
      components[["catalog"]]
    } else {
      current[["catalog"]]
    },
    schema = if ("schema" %in% names(components)) {
      components[["schema"]]
    } else {
      current[["schema"]]
    },
    table = components[["table"]]
  )
}

databricks_id_type <- function(id, call = rlang::caller_env()) {
  catalog_id_type(id, "Databricks", call = call)
}

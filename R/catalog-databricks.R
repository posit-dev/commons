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
  catalog_table_registry(
    con,
    tables,
    current_namespace = databricks_current_namespace,
    id_type = databricks_id_type,
    exact_relation = databricks_exact_relation,
    list_relations = databricks_list_relations,
    call = call
  )
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
  databricks_relations_from_information_schema(rows)
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
  requested_name <- components[["table"]]
  is_requested <- vapply(
    relations,
    function(relation) {
      identical(relation$id@name[["table"]], requested_name)
    },
    logical(1)
  )
  if (!any(is_requested)) {
    return(list(id = id, kind = NULL, description = NULL))
  }

  relation <- relations[[which(is_requested)[[1]]]]
  relation$id <- id
  relation
}

databricks_relations_from_information_schema <- function(rows) {
  names(rows) <- tolower(names(rows))
  lapply(seq_len(nrow(rows)), function(i) {
    description <- rows$comment[[i]]
    if (is.na(description) || !nzchar(description)) {
      description <- NULL
    }
    kind <- if (grepl("view", rows$table_type[[i]], ignore.case = TRUE)) {
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
  components <- id@name
  roles <- names(components)
  valid <- list(
    c("catalog"),
    c("schema"),
    c("catalog", "schema"),
    c("table"),
    c("schema", "table"),
    c("catalog", "schema", "table")
  )
  if (
    !any(vapply(valid, identical, logical(1), roles)) ||
      any(is.na(components) | !nzchar(components))
  ) {
    cli::cli_abort(
      "Databricks {.cls DBI::Id} entries in {.arg tables} must follow
       catalog, schema, and table order without skipped or empty components.",
      call = call
    )
  }
  if ("table" %in% roles) "relation" else "namespace"
}

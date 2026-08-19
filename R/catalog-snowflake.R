is_snowflake_connection <- function(con) {
  info <- tryCatch(DBI::dbGetInfo(con), error = function(err) NULL)
  name <- info$dbms.name
  rlang::is_string(name) && identical(tolower(name), "snowflake")
}

snowflake_table_registry <- function(
  con,
  tables = NULL,
  call = rlang::caller_env()
) {
  selection <- snowflake_catalog_selection(con, tables, call = call)
  registry <- catalog_table_registry(
    con,
    selection$relations,
    current_namespace = snowflake_current_namespace,
    id_type = snowflake_id_type,
    exact_relation = snowflake_exact_relation,
    list_relations = snowflake_list_relations,
    call = call
  )
  registry <- catalog_exclude_relations(
    registry,
    names(selection$semantic_views)
  )
  registry$semantic_models <- lapply(
    selection$semantic_views,
    snowflake_read_semantic_model,
    con = con,
    call = call
  )
  registry
}

snowflake_catalog_selection <- function(
  con,
  tables,
  call = rlang::caller_env()
) {
  ids <- if (is.null(tables)) {
    list(snowflake_current_namespace(con, call = call))
  } else {
    entries <- table_entries(tables, call = call)
    lapply(entries, table_entry_id, call = call)
  }
  semantic_views <- unlist(
    lapply(ids, function(id) {
      if (identical(snowflake_id_type(id, call = call), "namespace")) {
        snowflake_list_semantic_views(con, id, call = call)
      } else {
        snowflake_exact_semantic_view(con, id, call = call)
      }
    }),
    recursive = FALSE
  )
  semantic_labels <- vapply(
    semantic_views,
    function(view) table_id_label(view$id, call = call),
    character(1)
  )
  duplicated_labels <- unique(semantic_labels[duplicated(semantic_labels)])
  if (length(duplicated_labels)) {
    cli::cli_abort(
      "{.arg tables} must not select duplicate semantic models: {.val {duplicated_labels}}.",
      call = call
    )
  }
  names(semantic_views) <- semantic_labels

  relations <- Filter(function(id) {
    !identical(snowflake_id_type(id, call = call), "relation") ||
      !table_id_label(id, call = call) %in% semantic_labels
  }, ids)
  list(relations = relations, semantic_views = semantic_views)
}

snowflake_current_namespace <- function(con, call = rlang::caller_env()) {
  row <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT CURRENT_DATABASE() AS catalog,",
        "CURRENT_SCHEMA() AS schema"
      )
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to read the current Snowflake namespace.",
        parent = err,
        call = call
      )
    }
  )
  names(row) <- tolower(names(row))
  if (nrow(row) != 1L || !all(c("catalog", "schema") %in% names(row))) {
    cli::cli_abort(
      "Snowflake returned an invalid current namespace.",
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
        "The Snowflake connection has no current database and schema.",
        "i" = "Set both on the connection or supply {.arg tables} as a {.cls DBI::Id}."
      ),
      call = call
    )
  }
  DBI::Id(catalog = values[["catalog"]], schema = values[["schema"]])
}

snowflake_list_relations <- function(con, namespace, call = rlang::caller_env()) {
  components <- namespace@name
  target <- if (identical(names(components), "catalog")) {
    paste("IN DATABASE", DBI::dbQuoteIdentifier(con, namespace))
  } else {
    paste("IN SCHEMA", DBI::dbQuoteIdentifier(con, namespace))
  }
  rows <- tryCatch(
    DBI::dbGetQuery(con, paste("SHOW OBJECTS", target)),
    error = function(err) {
      cli::cli_abort(
        "Failed to list relations in the selected Snowflake namespace.",
        parent = err,
        call = call
      )
    }
  )
  snowflake_relations_from_show(rows)
}

snowflake_list_semantic_views <- function(
  con,
  namespace,
  name = NULL,
  call = rlang::caller_env()
) {
  components <- namespace@name
  target <- if (identical(names(components), "catalog")) {
    paste("IN DATABASE", DBI::dbQuoteIdentifier(con, namespace))
  } else {
    paste("IN SCHEMA", DBI::dbQuoteIdentifier(con, namespace))
  }
  sql <- paste(
    "SHOW SEMANTIC VIEWS",
    if (!is.null(name)) paste("LIKE", DBI::dbQuoteString(con, name)),
    target
  )
  # Missing semantic metadata should not block ordinary relation discovery.
  rows <- tryCatch(
    DBI::dbGetQuery(con, sql),
    error = function(err) NULL
  )
  if (is.null(rows)) {
    return(list())
  }
  snowflake_semantic_views_from_show(rows)
}

snowflake_exact_semantic_view <- function(
  con,
  id,
  call = rlang::caller_env()
) {
  components <- id@name
  current <- if (!all(c("catalog", "schema") %in% names(components))) {
    snowflake_current_namespace(con, call = call)@name
  }
  namespace <- DBI::Id(
    catalog = if ("catalog" %in% names(components)) {
      components[["catalog"]]
    } else {
      current[["catalog"]]
    },
    schema = if ("schema" %in% names(components)) {
      components[["schema"]]
    } else {
      current[["schema"]]
    }
  )
  views <- snowflake_list_semantic_views(
    con,
    namespace,
    name = components[["table"]],
    call = call
  )
  matches <- vapply(views, function(view) {
    identical(view$id@name[["table"]], components[["table"]])
  }, logical(1))
  if (!any(matches)) {
    return(list())
  }
  view <- views[[which(matches)[[1]]]]
  view$id <- id
  list(view)
}

snowflake_semantic_views_from_show <- function(rows) {
  names(rows) <- tolower(names(rows))
  if (nrow(rows) == 0L) {
    return(list())
  }
  lapply(seq_len(nrow(rows)), function(i) {
    description <- rows$comment[[i]]
    if (is.na(description) || !nzchar(description)) {
      description <- NULL
    }
    list(
      id = DBI::Id(
        catalog = rows$database_name[[i]],
        schema = rows$schema_name[[i]],
        table = rows$name[[i]]
      ),
      description = description
    )
  })
}

snowflake_exact_relation <- function(con, id, call = rlang::caller_env()) {
  components <- id@name
  namespace <- components[setdiff(names(components), "table")]
  if (length(namespace) == 0L) {
    namespace <- snowflake_current_namespace(con, call = call)@name
  }
  namespace <- do.call(DBI::Id, as.list(namespace))
  target <- paste("IN SCHEMA", DBI::dbQuoteIdentifier(con, namespace))
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SHOW OBJECTS LIKE",
        DBI::dbQuoteString(con, components[["table"]]),
        target
      )
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to read metadata for the selected Snowflake relation.",
        parent = err,
        call = call
      )
    }
  )
  relations <- snowflake_relations_from_show(rows)
  catalog_match_exact_relation(relations, id)
}

snowflake_relations_from_show <- function(rows) {
  names(rows) <- tolower(names(rows))
  if (nrow(rows) == 0L) {
    return(list())
  }
  rows <- rows[toupper(rows$kind) %in% c("TABLE", "VIEW"), , drop = FALSE]
  lapply(seq_len(nrow(rows)), function(i) {
    description <- rows$comment[[i]]
    if (is.na(description) || !nzchar(description)) {
      description <- NULL
    }
    list(
      id = DBI::Id(
        catalog = rows$database_name[[i]],
        schema = rows$schema_name[[i]],
        table = rows$name[[i]]
      ),
      kind = tolower(rows$kind[[i]]),
      description = description
    )
  })
}

snowflake_describe_relation <- function(con, id, call = rlang::caller_env()) {
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste("DESC TABLE", DBI::dbQuoteIdentifier(con, id))
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to describe the selected Snowflake relation.",
        parent = err,
        call = call
      )
    }
  )
  names(rows) <- tolower(names(rows))
  rows <- rows[toupper(rows$kind) == "COLUMN", , drop = FALSE]
  description <- rows$comment
  description[is.na(description) | !nzchar(description)] <- NA_character_
  data.frame(
    column = rows$name,
    type = rows$type,
    nullable = rows[["null?"]] == "Y",
    description = description,
    row.names = NULL
  )
}

snowflake_read_semantic_model <- function(
  view,
  con,
  call = rlang::caller_env()
) {
  rlang::check_installed("yaml", call = call)
  label <- as.character(DBI::dbQuoteIdentifier(con, view$id))
  sql <- paste0(
    "SELECT SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW(",
    DBI::dbQuoteString(con, label),
    ") AS specification"
  )
  text <- tryCatch(
    DBI::dbGetQuery(con, sql)[[1]][[1]],
    error = function(err) {
      cli::cli_abort(
        "Failed to read Snowflake semantic view {.val {label}}.",
        parent = err,
        call = call
      )
    }
  )
  specification <- tryCatch(
    yaml::yaml.load(text),
    error = function(err) {
      cli::cli_abort(
        "Snowflake semantic view {.val {label}} returned invalid YAML.",
        parent = err,
        call = call
      )
    }
  )
  snowflake_semantic_model_from_spec(
    view$id,
    specification,
    description = view$description
  )
}

snowflake_semantic_model_from_spec <- function(
  id,
  specification,
  description = NULL
) {
  dimensions <- list()
  metrics <- list()
  for (table in semantic_spec_entries(specification$tables)) {
    dimensions <- c(
      dimensions,
      snowflake_semantic_members(table$dimensions, "dimension", table$name),
      snowflake_semantic_members(
        table$time_dimensions,
        "dimension",
        table$name
      )
    )
    metrics <- c(
      metrics,
      snowflake_semantic_members(table$metrics, "metric", table$name)
    )
  }
  metrics <- c(
    metrics,
    snowflake_semantic_members(specification$metrics, "metric")
  )
  new_semantic_model(
    id,
    name = specification$name %||% id@name[["table"]],
    description = specification$description %||% description,
    backend = "snowflake_semantic_view",
    dimensions = dimensions,
    metrics = metrics
  )
}

snowflake_semantic_members <- function(entries, kind, parent = NULL) {
  members <- list()
  for (item in semantic_spec_entries(entries)) {
    if (!snowflake_semantic_member_is_public(item)) {
      next
    }
    name <- item$name
    if (!rlang::is_string(name) || !nzchar(name)) {
      next
    }
    members[[length(members) + 1L]] <- new_semantic_member(
      name,
      kind,
      parent = parent,
      label = item$label,
      description = item$description %||% item$comment,
      type = item$data_type,
      synonyms = unlist(item$synonyms %||% character(), use.names = FALSE)
    )
  }
  members
}

snowflake_semantic_member_is_public <- function(member) {
  modifier <- tolower(member$access_modifier %||% "public_access")
  !modifier %in% c("private", "private_access")
}

snowflake_semantic_metric_sql <- function(
  model,
  metrics,
  dimensions,
  where,
  members,
  con
) {
  parts <- c(
    as.character(DBI::dbQuoteIdentifier(con, model$id)),
    if (nrow(dimensions)) {
      paste(
        "DIMENSIONS",
        paste(
          snowflake_semantic_member_references(dimensions, con),
          collapse = ", "
        )
      )
    },
    paste(
      "METRICS",
      paste(snowflake_semantic_member_references(metrics, con), collapse = ", ")
    )
  )
  conditions <- snowflake_semantic_where(where, members, con)
  if (length(conditions)) {
    parts <- c(parts, paste("WHERE", paste(conditions, collapse = " AND ")))
  }
  paste0(
    "SELECT * FROM SEMANTIC_VIEW(\n  ",
    paste(parts, collapse = "\n  "),
    "\n)"
  )
}

snowflake_semantic_member_references <- function(members, con) {
  vapply(seq_len(nrow(members)), function(i) {
    parent <- members$parent[[i]]
    if (is.na(parent) || !nzchar(parent)) {
      return(as.character(DBI::dbQuoteIdentifier(con, members$name[[i]])))
    }
    as.character(DBI::dbQuoteIdentifier(
      con,
      DBI::Id(schema = parent, table = members$name[[i]])
    ))
  }, character(1))
}

snowflake_semantic_where <- function(where, members, con) {
  semantic_where_conditions(
    where,
    members,
    con,
    snowflake_semantic_member_references
  )
}

snowflake_id_type <- function(id, call = rlang::caller_env()) {
  catalog_id_type(id, "Snowflake", call = call)
}

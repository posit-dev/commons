is_snowflake_connection <- function(con) {
  info <- tryCatch(DBI::dbGetInfo(con), error = function(err) NULL)
  name <- info$dbms.name
  rlang::is_string(name) && identical(tolower(name), "snowflake")
}

snowflake_table_registry <- function(
  con,
  tables = NULL,
  exclude = NULL,
  call = rlang::caller_env()
) {
  selection <- snowflake_catalog_selection(
    con,
    tables,
    exclude = exclude,
    call = call
  )
  registry <- catalog_table_registry(
    con,
    selection$relations,
    current_namespace = snowflake_current_namespace,
    id_type = snowflake_id_type,
    exact_relation = snowflake_exact_relation,
    list_relations = snowflake_list_relations,
    exclude = exclude,
    call = call
  )
  registry <- catalog_exclude_relations(
    registry,
    names(selection$semantic_views)
  )
  catalog_check_object_limit(
    length(registry$relations) + length(selection$semantic_views),
    call = call
  )
  # Exact selections fail early; namespace models load when inspected or used.
  eager_views <- selection$semantic_views[selection$semantic_validate]
  registry$semantic_models <- lapply(
    eager_views,
    snowflake_read_semantic_model,
    con = con,
    call = call
  )
  unsupported <- vapply(
    registry$semantic_models,
    inherits,
    logical(1),
    "commons_unsupported_snowflake_semantic_view"
  )
  if (any(unsupported)) {
    snowflake_abort_unsupported_semantic_views(
      registry$semantic_models[unsupported],
      call = call
    )
  }
  registry$semantic_models <- c(
    registry$semantic_models,
    snowflake_associated_semantic_models(
      con,
      registry,
      exclude = exclude,
      call = call
    )
  )
  registry$semantic_models <- catalog_exclude_semantic_models(
    registry$semantic_models,
    exclude
  )
  stub_labels <- setdiff(
    names(selection$semantic_views),
    c(selection$semantic_validate, names(registry$semantic_models))
  )
  registry$semantic_stubs <- lapply(
    selection$semantic_views[stub_labels],
    new_semantic_model_stub,
    backend = "snowflake_semantic_view"
  )
  registry$semantic_validate <- selection$semantic_validate
  catalog_check_object_limit(
    length(registry$relations) +
      length(registry$semantic_models) +
      length(registry$semantic_stubs),
    call = call
  )
  catalog_check_nonempty(registry, call = call)
}

snowflake_abort_unsupported_semantic_views <- function(models, call) {
  problems <- vapply(models, `[[`, character(1), "reason")
  cli::cli_abort(
    c(
      "Some selected Snowflake semantic views are not supported:",
      stats::setNames(paste0(names(problems), ": ", problems), "*")
    ),
    call = call
  )
}

snowflake_associated_semantic_models <- function(
  con,
  registry,
  exclude = NULL,
  call = rlang::caller_env()
) {
  seeds <- Filter(
    semantic_association_seed,
    registry$relations[registry$validate$labels]
  )
  if (length(seeds) == 0L) {
    return(list())
  }
  namespaces <- lapply(seeds, function(relation) {
    identity <- relation$identity
    do.call(DBI::Id, as.list(identity@name[c("catalog", "schema")]))
  })
  namespace_keys <- vapply(
    namespaces,
    semantic_id_key,
    character(1),
    backend = "snowflake_semantic_view"
  )
  namespaces <- namespaces[!duplicated(namespace_keys)]
  views <- unlist(lapply(
    namespaces,
    snowflake_list_semantic_views,
    con = con,
    call = call
  ), recursive = FALSE)
  views <- views[!catalog_excluded(
    vapply(views, catalog_relation_name, character(1)),
    exclude
  )]
  view_keys <- vapply(
    views,
    function(view) {
      semantic_id_key(
        view$identity %||% view$id,
        "snowflake_semantic_view"
      )
    },
    character(1)
  )
  selected_keys <- vapply(
    registry$semantic_models,
    semantic_model_identity_key,
    character(1)
  )
  views <- views[!duplicated(view_keys) & !view_keys %in% selected_keys]
  catalog_check_object_limit(
    length(registry$relations) +
      length(registry$semantic_models) +
      length(views),
    call = call
  )
  models <- lapply(views, function(view) {
    tryCatch(
      snowflake_read_semantic_model(view, con, call = call),
      error = function(err) NULL
    )
  })
  keep <- !vapply(models, function(model) {
    is.null(model) ||
      inherits(model, "commons_unsupported_snowflake_semantic_view")
  }, logical(1))
  models <- semantic_models_in_scope(models[keep], registry$relations)
  names(models) <- vapply(
    models,
    function(model) table_id_label(model$id, call = call),
    character(1)
  )
  models
}

snowflake_catalog_selection <- function(
  con,
  tables,
  exclude = NULL,
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
  semantic_views <- semantic_views[!catalog_excluded(
    vapply(semantic_views, catalog_relation_name, character(1)),
    exclude
  )]
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
  exact_labels <- vapply(
    Filter(
      function(id) identical(snowflake_id_type(id, call = call), "relation"),
      ids
    ),
    table_id_label,
    character(1),
    call = call
  )

  relations <- Filter(function(id) {
    !identical(snowflake_id_type(id, call = call), "relation") ||
      !table_id_label(id, call = call) %in% semantic_labels
  }, ids)
  list(
    relations = relations,
    semantic_views = semantic_views,
    semantic_validate = intersect(semantic_labels, exact_labels)
  )
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
  snowflake_check_show_complete(rows, "relations", call = call)
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
  snowflake_check_show_complete(rows, "semantic views", call = call)
  snowflake_semantic_views_from_show(rows)
}

snowflake_check_show_complete <- function(
  rows,
  objects,
  call = rlang::caller_env()
) {
  if (nrow(rows) >= snowflake_show_row_limit) {
    cli::cli_abort(c(
      paste(
        "Snowflake returned {snowflake_show_row_limit} {objects}, so the",
        "catalog selection might be truncated."
      ),
      i = "Narrow {.arg tables} to a smaller database or schema prefix."
    ), call = call)
  }
  invisible(rows)
}

snowflake_show_row_limit <- 10000L

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
  view$identity <- view$id
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
  snowflake_describe_rows(rows)
}

# Split from the query so the row handling is shared with the Python suite
# through tests/shared/catalog-rows.json.
snowflake_describe_rows <- function(rows) {
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
  model <- tryCatch(
    snowflake_semantic_model_from_spec(
      view$id,
      specification,
      description = view$description
    ),
    commons_unsupported_semantic_parameter = function(err) {
      snowflake_unsupported_semantic_view(view$id, conditionMessage(err))
    }
  )
  if (inherits(model, "commons_unsupported_snowflake_semantic_view")) {
    return(model)
  }
  model$identity <- view$identity %||% view$id
  model
}

snowflake_unsupported_semantic_view <- function(id, reason) {
  structure(
    list(id = id, reason = reason),
    class = "commons_unsupported_snowflake_semantic_view"
  )
}

snowflake_semantic_model_from_spec <- function(
  id,
  specification,
  description = NULL
) {
  dimensions <- list()
  facts <- list()
  filters <- list()
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
    facts <- c(
      facts,
      snowflake_semantic_members(table$facts, "fact", table$name)
    )
    filters <- c(
      filters,
      snowflake_semantic_members(table$filters, "filter", table$name)
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
  dependencies <- snowflake_semantic_dependencies(id, specification)
  relationships <- specification$relationships %||% list()
  parameters <- semantic_parameters_from_spec(
    specification$variables,
    "Snowflake"
  )
  calculations <- snowflake_verified_calculations(
    specification$verified_queries
  )
  context <- snowflake_semantic_context(
    specification,
    dimensions,
    facts,
    filters,
    relationships
  )
  new_semantic_model(
    id,
    name = specification$name %||% id@name[["table"]],
    description = specification$description %||% description,
    backend = "snowflake_semantic_view",
    dimensions = dimensions,
    metrics = metrics,
    facts = facts,
    filters = filters,
    parameters = parameters,
    calculations = calculations,
    dependencies = dependencies$ids,
    dependencies_complete = dependencies$complete,
    relationships = relationships,
    context = list(first_touch = context, retrieval = context)
  )
}

snowflake_verified_calculations <- function(entries) {
  calculations <- lapply(semantic_spec_entries(entries), function(entry) {
    if (
      !rlang::is_string(entry$name) ||
        !nzchar(entry$name) ||
        !rlang::is_string(entry$sql) ||
        !nzchar(entry$sql)
    ) {
      cli::cli_abort("Snowflake declares an invalid verified query.")
    }
    new_trusted_calculation(
      entry$name,
      entry$question %||% entry$name,
      entry$sql
    )
  })
  names(calculations) <- vapply(calculations, `[[`, character(1), "name")
  if (anyDuplicated(names(calculations))) {
    cli::cli_abort("Snowflake verified query names must be unique.")
  }
  calculations
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
      synonyms = unlist(item$synonyms %||% character(), use.names = FALSE),
      filter = "filter" %in% tolower(unlist(
        item$labels %||% character(),
        use.names = FALSE
      ))
    )
  }
  members
}

snowflake_semantic_member_is_public <- function(member) {
  modifier <- tolower(member$access_modifier %||% "public_access")
  !modifier %in% c("private", "private_access")
}

snowflake_semantic_dependencies <- function(id, specification) {
  model <- id@name
  ids <- list()
  complete <- TRUE
  for (table in semantic_spec_entries(specification$tables)) {
    base <- table$base_table %||% list()
    table_name <- base$table
    catalog <- base$database %||% base$catalog %||% model[["catalog"]]
    schema <- base$schema %||% model[["schema"]]
    if (
      !rlang::is_string(catalog) ||
        !rlang::is_string(schema) ||
        !rlang::is_string(table_name)
    ) {
      complete <- FALSE
      next
    }
    ids[[length(ids) + 1L]] <- DBI::Id(
      catalog = catalog,
      schema = schema,
      table = table_name
    )
  }
  keys <- vapply(
    ids,
    semantic_id_key,
    character(1),
    backend = "snowflake_semantic_view"
  )
  list(ids = ids[!duplicated(keys)], complete = complete && length(ids) > 0L)
}

snowflake_semantic_context <- function(
  specification,
  dimensions,
  facts,
  filters,
  relationships
) {
  instructions <- unique(as.character(unlist(c(
    specification$custom_instructions,
    specification$module_custom_instructions
  ), use.names = FALSE)))
  instructions <- instructions[!is.na(instructions) & nzchar(instructions)]
  relationship_text <- vapply(
    relationships,
    snowflake_semantic_relationship_text,
    character(1)
  )
  entity_filters <- c(
    Filter(function(member) isTRUE(member$filter), dimensions),
    Filter(function(member) isTRUE(member$filter), facts)
  )
  c(
    instructions,
    relationship_text,
    semantic_members_context(facts, "Native semantic facts"),
    semantic_members_context(
      c(entity_filters, filters),
      "Native semantic filters"
    )
  )
}

snowflake_semantic_relationship_text <- function(relationship) {
  name <- relationship$name %||% "unnamed"
  left <- relationship$left_table %||% relationship$from_table %||% "unknown"
  right <- relationship$right_table %||% relationship$to_table %||% "unknown"
  columns <- vapply(
    relationship$relationship_columns %||% list(),
    function(column) {
      paste(
        column$left_column %||% column$from_column %||% "?",
        column$right_column %||% column$to_column %||% "?",
        sep = " = "
      )
    },
    character(1)
  )
  paste0(
    "Semantic relationship `", name, "` links `", left, "` to `", right, "`",
    if (length(columns)) paste0(" on ", paste(columns, collapse = ", ")),
    "."
  )
}

snowflake_semantic_metric_sql <- function(
  model,
  metrics,
  dimensions,
  filters = NULL,
  where,
  members,
  con,
  arguments = list()
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
    ),
    if (length(arguments)) {
      paste(
        "VARIABLES",
        paste(
          sprintf(
            "%s => ?",
            DBI::dbQuoteIdentifier(con, names(arguments))
          ),
          collapse = ", "
        )
      )
    }
  )
  conditions <- c(
    snowflake_semantic_member_references(filters, con),
    snowflake_semantic_where(where, members, con)
  )
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
  if (is.null(members) || nrow(members) == 0L) {
    return(character())
  }
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

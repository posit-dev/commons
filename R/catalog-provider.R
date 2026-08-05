new_catalog_provider <- function(con, options, call = rlang::caller_env()) {
  started_at <- Sys.time()
  backend <- catalog_backend(con)
  catalog_progress("discovering", backend, started_at)
  snapshot <- catalog_connection_snapshot(con, backend)
  capabilities <- catalog_backend_capabilities(con, backend, snapshot)
  source_id <- catalog_id(
    "source",
    backend,
    snapshot$principal %||% "unknown",
    paste(unlist(snapshot$namespace), collapse = ".")
  )
  ids <- catalog_resolve_selection(con, backend, options, call)
  if (length(ids) > catalog_object_limit) {
    cli::cli_abort(c(
      "The data-source selection resolves to {length(ids)} objects, above the supported limit of {catalog_object_limit}.",
      "i" = "Narrow {.arg include} to fewer catalog or schema prefixes."
    ), call = call)
  }
  if (length(ids) == 0) {
    cli::cli_abort(
      "The resolved data-source selection contains no queryable objects.",
      call = call
    )
  }
  names <- vapply(ids, catalog_id_name, character(1))
  keep <- !catalog_excluded(names, options$exclude)
  ids <- ids[keep]
  if (length(ids) == 0) {
    cli::cli_abort(
      "{.arg exclude} removes every object in the data-source selection.",
      call = call
    )
  }

  keys <- vapply(ids, catalog_source_path_key, character(1))
  ids <- catalog_collapse_selected_ids(ids, keys)
  labels <- vapply(ids, catalog_id_label, character(1))
  labels <- catalog_unique_labels(labels, ids, call)
  names(ids) <- labels

  provenance <- new_catalog_provenance(
    "discovered",
    source_id,
    harvested_at = Sys.time()
  )
  source <- new_catalog_source(
    id = source_id,
    kind = backend,
    dialect = backend,
    locator = snapshot$locator,
    selection = options,
    principal = snapshot$principal,
    role = snapshot$role,
    namespace = snapshot$namespace,
    identifier_case = catalog_identifier_case(backend),
    sample_rows = options$sample_rows,
    version = snapshot$version,
    provenance = provenance
  )
  source$extensions$capabilities <- capabilities
  relations <- lapply(seq_along(ids), function(i) {
    id <- ids[[i]]
    path <- new_source_path(id)
    new_catalog_relation(
      id = catalog_id("relation", source_id, catalog_source_path_key(id)),
      source_id = source_id,
      path = path,
      kind = attr(id, "commons_kind") %||% "unknown",
      name = catalog_id_name(id),
      description = attr(id, "commons_description"),
      access = new_catalog_access("unknown", "listed by the connection"),
      provenance = provenance
    )
  })
  relation_ids <- vapply(relations, `[[`, character(1), "id")
  relation_labels <- stats::setNames(labels, relation_ids)

  provider <- new.env(parent = emptyenv())
  provider$con <- con
  provider$backend <- backend
  provider$options <- options
  provider$snapshot <- snapshot
  provider$capabilities <- capabilities
  provider$table_ids <- ids
  provider$relation_labels <- relation_labels
  provider$selection_modes <- stats::setNames(
    vapply(ids, function(id) attr(id, "commons_selection") %||% "exact", character(1)),
    relation_ids
  )
  provider$catalog <- new_commons_catalog(
    sources = list(source),
    relations = relations,
    provider = provider
  )
  provider$lazy <- nchar(paste(labels, collapse = "\n"), type = "bytes") > 4000L
  catalog_import_backend(provider)
  provider$startup <- list(
    started_at = started_at,
    elapsed = as.numeric(difftime(Sys.time(), started_at, units = "secs"))
  )
  catalog_progress("ready", backend, started_at)
  provider
}

catalog_object_limit <- 25000L

catalog_backend_capabilities <- function(con, backend, snapshot) {
  hierarchy <- if (requireNamespace("odbc", quietly = TRUE) &&
      inherits(con, "OdbcConnection")) {
    tryCatch(odbc::odbcListObjectTypes(con), error = function(err) NULL)
  }
  list(
    odbc_hierarchy = hierarchy,
    describe_json = if (identical(backend, "databricks")) "probe_on_use" else NULL,
    native_semantics = backend %in% c("snowflake", "databricks"),
    version = snapshot$version
  )
}

catalog_odbc_objects <- function(con, catalog = NULL, schema = NULL) {
  if (!requireNamespace("odbc", quietly = TRUE) ||
      !inherits(con, "OdbcConnection")) {
    return(NULL)
  }
  tryCatch(
    odbc::odbcListObjects(con, catalog = catalog, schema = schema),
    error = function(err) NULL
  )
}

catalog_backend <- function(con) {
  info <- tryCatch(DBI::dbGetInfo(con), error = function(err) list())
  label <- paste(
    c(info$dbms.name, info$dbname, class(con)),
    collapse = " "
  )
  if (grepl("snowflake", label, ignore.case = TRUE)) {
    return("snowflake")
  }
  if (grepl("databricks|spark", label, ignore.case = TRUE)) {
    return("databricks")
  }
  tolower(info$dbms.name %||% sub("Connection$", "", class(con)[[1]]))
}

catalog_connection_snapshot <- function(con, backend) {
  if (identical(backend, "snowflake")) {
    return(snowflake_connection_snapshot(con))
  }
  if (identical(backend, "databricks")) {
    return(databricks_connection_snapshot(con))
  }
  info <- tryCatch(DBI::dbGetInfo(con), error = function(err) list())
  list(
    backend = backend,
    locator = catalog_compact(list(
      dbname = info$dbname,
      host = info$host,
      port = info$port
    )),
    principal = info$username %||% info$user,
    role = NULL,
    namespace = catalog_compact(list(
      catalog = info$dbname,
      schema = info$schema
    ))
  )
}

catalog_provider_check <- function(provider, call = rlang::caller_env()) {
  current <- catalog_connection_snapshot(provider$con, provider$backend)
  if (!identical(current, provider$snapshot)) {
    cli::cli_abort(
      "The connection identity, role, or current namespace changed after catalog discovery; rebuild the data source.",
      call = call
    )
  }
  invisible(provider)
}

catalog_resolve_selection <- function(con, backend, options, call) {
  includes <- normalize_connection_includes(options$include, call)
  if (is.null(includes)) {
    objects <- catalog_default_objects(con, backend, call)
    return(lapply(objects, catalog_selection_id, "namespace"))
  }

  objects <- list()
  for (include in includes) {
    if ("table" %in% names(include@name)) {
      objects[[length(objects) + 1]] <- catalog_selection_id(include, "exact")
    } else {
      expanded <- catalog_list_namespace(con, backend, include, call)
      expanded <- lapply(expanded, catalog_selection_id, "namespace")
      objects <- c(objects, expanded)
    }
  }
  objects
}

catalog_selection_id <- function(id, mode) {
  attr(id, "commons_selection") <- mode
  id
}

catalog_collapse_selected_ids <- function(ids, keys) {
  unique_keys <- unique(keys)
  lapply(unique_keys, function(key) {
    matches <- which(keys == key)
    kinds <- vapply(
      ids[matches],
      function(candidate) attr(candidate, "commons_kind") %||% "unknown",
      character(1)
    )
    priority <- match(
      kinds,
      c("semantic_view", "metric_view", "view", "table", "unknown")
    )
    id <- ids[[matches[[which.min(priority)]]]]
    modes <- vapply(
      ids[matches],
      function(candidate) attr(candidate, "commons_selection") %||% "exact",
      character(1)
    )
    attr(id, "commons_selection") <- if ("namespace" %in% modes) {
      "namespace"
    } else {
      "exact"
    }
    id
  })
}

catalog_default_objects <- function(con, backend, call) {
  if (identical(backend, "snowflake")) {
    return(snowflake_default_objects(con, call))
  }
  if (identical(backend, "databricks")) {
    return(databricks_default_objects(con, call))
  }
  tables <- tryCatch(
    DBI::dbListTables(con),
    error = function(err) {
      cli::cli_abort(
        "Failed to discover objects in the connection's current namespace.",
        parent = err,
        call = call
      )
    }
  )
  tables <- tables[vapply(tables, function(table) {
    isTRUE(DBI::dbExistsTable(con, DBI::Id(table = table)))
  }, logical(1))]
  if (length(tables) == 0) {
    cli::cli_abort(
      c(
        "The connection has no current-namespace objects.",
        "i" = "Set a current catalog/database and schema, or supply {.arg options} with explicit {.arg include} IDs."
      ),
      call = call
    )
  }
  lapply(tables, function(table) DBI::Id(table = table))
}

catalog_list_namespace <- function(con, backend, prefix, call) {
  if (identical(backend, "snowflake")) {
    return(snowflake_list_namespace(con, prefix, call))
  }
  if (identical(backend, "databricks")) {
    return(databricks_list_namespace(con, prefix, call))
  }
  listed <- tryCatch(
    DBI::dbListObjects(con, prefix = prefix),
    error = function(err) NULL
  )
  if (!is.null(listed) && all(c("table", "is_prefix") %in% names(listed))) {
    ids <- unclass(listed$table)
    ids <- ids[!listed$is_prefix]
    ids <- Filter(function(id) catalog_id_has_prefix(id, prefix), ids)
    if (length(ids)) {
      return(ids)
    }
  }
  ids <- catalog_information_schema_objects(con, prefix)
  if (length(ids)) {
    return(ids)
  }
  cli::cli_abort(
    "The {backend} DBI driver cannot enumerate namespace {.val {paste(prefix@name, collapse = '.')}}; select exact table IDs instead.",
    call = call
  )
}

catalog_information_schema_objects <- function(con, prefix) {
  components <- prefix@name
  catalog <- catalog_path_component(components, "catalog") %||%
    catalog_path_component(components, "database")
  schema <- catalog_path_component(components, "schema")
  table_id <- DBI::Id(schema = "information_schema", table = "tables")
  predicates <- c(
    if (!is.null(catalog)) {
      paste0("table_catalog = ", DBI::dbQuoteString(con, catalog))
    },
    if (!is.null(schema)) {
      paste0("table_schema = ", DBI::dbQuoteString(con, schema))
    }
  )
  sql <- paste0(
    "SELECT table_catalog, table_schema, table_name FROM ",
    DBI::dbQuoteIdentifier(con, table_id),
    if (length(predicates)) paste0(" WHERE ", paste(predicates, collapse = " AND "))
  )
  rows <- tryCatch(DBI::dbGetQuery(con, sql), error = function(err) NULL)
  if (is.null(rows) || nrow(rows) == 0) {
    return(list())
  }
  rows <- stats::setNames(rows, tolower(names(rows)))
  lapply(seq_len(nrow(rows)), function(i) {
    values <- list()
    if ("catalog" %in% names(components)) {
      values$catalog <- rows$table_catalog[[i]]
    }
    if ("database" %in% names(components)) {
      values$database <- rows$table_catalog[[i]]
    }
    values$schema <- rows$table_schema[[i]]
    values$table <- rows$table_name[[i]]
    do.call(DBI::Id, values)
  })
}

catalog_path_component <- function(components, role) {
  if (!role %in% names(components)) {
    return(NULL)
  }
  unname(components[[role]])
}

catalog_id_has_prefix <- function(id, prefix) {
  components <- id@name
  expected <- prefix@name
  roles <- names(expected)
  all(roles %in% names(components)) && identical(
    unname(components[roles]),
    unname(expected)
  )
}

catalog_provider_hydrate <- function(provider, table, call = rlang::caller_env()) {
  catalog_provider_check(provider, call)
  id <- provider$table_ids[[table]]
  if (is.null(id)) {
    cli::cli_abort(
      c(
        "No table named {.val {table}}.",
        "i" = "Available tables: {.val {names(provider$table_ids)}}."
      ),
      call = call
    )
  }
  relation_id <- names(provider$relation_labels)[provider$relation_labels == table]
  relation <- provider$catalog$relations[[relation_id]]
  if (length(relation$columns)) {
    return(relation)
  }
  if (identical(relation$kind, "semantic_view")) {
    definitions <- Filter(
      function(x) identical(x$relation_id, relation$id) &&
        identical(x$visibility, "public"),
      provider$catalog$definitions
    )
    relation$columns <- lapply(definitions, function(definition) {
      new_catalog_column(
        definition$name,
        logical_type = definition$logical_type,
        description = definition$description,
        provenance = definition$provenance
      )
    })
    names(relation$columns) <- vapply(
      relation$columns,
      `[[`,
      character(1),
      "name"
    )
    relation <- genie_apply_column_overrides(relation)
    provider$catalog$relations[[relation_id]] <- relation
    return(relation)
  }

  metadata <- tryCatch(
    catalog_relation_metadata(provider$con, id),
    error = function(err) err
  )
  if (inherits(metadata, "condition")) {
    metadata$message <- gsub(
      "\\r?\\n[ \\t]*\\r?\\n",
      "\n",
      conditionMessage(metadata),
      perl = TRUE
    )
    relation$access <- new_catalog_access("visible_only", conditionMessage(metadata))
    provider$catalog$relations[[relation_id]] <- relation
    cli::cli_abort(
      "Table {.val {table}} could not be described.",
      parent = metadata,
      call = call
    )
  }

  relation$columns <- metadata$columns
  relation$constraints <- metadata$constraints %||% relation$constraints
  relation$kind <- metadata$kind %||% relation$kind
  relation$access <- new_catalog_access("queryable", "zero-row metadata query")
  relation <- genie_apply_column_overrides(relation)
  provider$catalog$relations[[relation_id]] <- relation
  relation
}

catalog_relation_metadata <- function(con, id) {
  backend <- catalog_backend(con)
  if (identical(backend, "snowflake")) {
    return(snowflake_relation_metadata(con, id))
  }
  if (identical(backend, "databricks")) {
    return(databricks_relation_metadata(con, id))
  }
  result <- DBI::dbSendQuery(
    con,
    sprintf(
      "SELECT * FROM %s WHERE 1 = 0",
      DBI::dbQuoteIdentifier(con, id)
    )
  )
  on.exit(DBI::dbClearResult(result), add = TRUE)
  info <- DBI::dbColumnInfo(result)
  columns <- lapply(seq_len(nrow(info)), function(i) {
    type <- if ("type" %in% names(info)) info$type[[i]] else NULL
    new_catalog_column(
      name = info$name[[i]],
      native_type = type,
      logical_type = type
    )
  })
  names(columns) <- vapply(columns, `[[`, character(1), "name")
  list(columns = columns, constraints = list(), kind = NULL)
}

catalog_provider_search <- function(provider, query, kinds = NULL, limit = 10L) {
  catalog_provider_check(provider)
  relations <- provider$catalog$relations
  if (!is.null(kinds)) {
    relations <- Filter(function(x) x$kind %in% kinds, relations)
  }
  relations <- Filter(
    function(x) !identical(x$access$state, "visible_only"),
    relations
  )
  if (length(relations) == 0) {
    return(relations)
  }
  query_terms <- catalog_search_terms(query)
  scores <- vapply(relations, function(relation) {
    text <- paste(
      relation$name,
      relation$label,
      relation$description,
      relation$tags,
      relation$synonyms
    )
    terms <- catalog_search_terms(text)
    sum(query_terms %in% terms) + sum(grepl(
      paste(query_terms, collapse = "|"),
      tolower(text)
    ))
  }, numeric(1))
  order <- order(scores, decreasing = TRUE)
  relations[utils::head(order, limit)]
}

catalog_search_terms <- function(x) {
  x <- tolower(paste(x %||% "", collapse = " "))
  unique(Filter(nzchar, strsplit(gsub("[^[:alnum:]_]+", " ", x), " +")[[1]]))
}

catalog_provider_searchable <- function(source) {
  !is.null(source$provider) && isTRUE(source$provider$lazy)
}

catalog_identifier_case <- function(backend) {
  if (identical(backend, "snowflake")) "upper" else "preserve"
}

catalog_id_name <- function(id) {
  unname(utils::tail(id@name, 1))
}

catalog_id_label <- function(id) {
  paste(unname(id@name), collapse = ".")
}

catalog_source_path_key <- function(id) {
  paste(paste(names(id@name), id@name, sep = "="), collapse = "/")
}

catalog_unique_labels <- function(labels, ids, call) {
  duplicates <- unique(labels[duplicated(labels)])
  if (length(duplicates)) {
    cli::cli_abort(
      "The selected objects do not have unique rendered names: {.val {duplicates}}.",
      call = call
    )
  }
  labels
}

catalog_tag_id <- function(id, kind = "table", description = NULL) {
  attr(id, "commons_kind") <- kind
  attr(id, "commons_description") <- description
  id
}

catalog_progress <- function(stage, backend, started_at) {
  condition <- structure(
    list(
      message = sprintf("%s catalog %s", backend, stage),
      stage = stage,
      backend = backend,
      elapsed = as.numeric(difftime(Sys.time(), started_at, units = "secs"))
    ),
    class = c("commons_catalog_progress", "condition")
  )
  signalCondition(condition)
  invisible(condition)
}

catalog_import_backend <- function(provider) {
  if (identical(provider$backend, "snowflake")) {
    snowflake_import_semantics(provider)
  } else if (identical(provider$backend, "databricks")) {
    databricks_import_semantics(provider)
    if (!is.null(provider$options$genie)) {
      genie_import(provider, provider$options$genie)
    }
  } else if (!is.null(provider$options$genie)) {
    cli::cli_abort("{.arg genie} is supported only for Databricks connections.")
  }
  invisible(provider)
}

catalog_association_prefixes <- function(provider) {
  relation_ids <- names(provider$selection_modes)[
    provider$selection_modes == "exact"
  ]
  relations <- provider$catalog$relations[relation_ids]
  relations <- Filter(function(relation) {
    !relation$kind %in% c("semantic_view", "metric_view") &&
      "table" %in% relation$path$roles
  }, relations)
  prefixes <- lapply(relations, function(relation) {
    keep <- relation$path$roles != "table"
    do.call(DBI::Id, as.list(stats::setNames(
      relation$path$components[keep],
      relation$path$roles[keep]
    )))
  })
  keys <- vapply(prefixes, catalog_source_path_key, character(1))
  prefixes[!duplicated(keys)]
}

catalog_add_associated_relation <- function(provider, id, kind) {
  path <- new_source_path(id)
  existing <- Filter(
    function(relation) identical(relation$path, path),
    provider$catalog$relations
  )
  if (length(existing)) {
    return(existing[[1]])
  }
  source <- provider$catalog$sources[[1]]
  provenance <- new_catalog_provenance(
    "discovered",
    source$id,
    harvested_at = Sys.time()
  )
  relation <- new_catalog_relation(
    catalog_id("relation", source$id, catalog_source_path_key(id)),
    source$id,
    path,
    kind = kind,
    name = catalog_id_name(id),
    description = attr(id, "commons_description"),
    access = new_catalog_access("unknown", "associated semantic object"),
    provenance = provenance
  )
  provider$catalog$relations[[relation$id]] <- relation
  relation
}

catalog_filter_associated_model <- function(provider, relation_id) {
  models <- Filter(
    function(model) relation_id %in% model$exposed,
    provider$catalog$models
  )
  if (length(models) == 0) {
    return(invisible(provider))
  }
  model <- models[[1]]
  selected <- names(provider$selection_modes)
  selected_paths <- vapply(
    provider$catalog$relations[selected],
    function(relation) catalog_source_path_key(source_path_id(relation$path)),
    character(1)
  )
  definitions <- Filter(
    function(definition) identical(definition$model_id, model$id),
    provider$catalog$definitions
  )
  calculations <- Filter(
    function(calculation) model$id %in% calculation$dependencies,
    provider$catalog$calculations
  )
  keep_definitions <- vapply(
    definitions,
    function(definition) {
      catalog_dependencies_selected(
        provider$catalog,
        definition$dependencies,
        selected_paths
      )
    },
    logical(1)
  )
  keep_calculations <- rep(
    catalog_dependencies_selected(
      provider$catalog,
      model$dependencies,
      selected_paths
    ),
    length(calculations)
  )
  skipped <- c(
    vapply(definitions[!keep_definitions], `[[`, character(1), "name"),
    vapply(calculations[!keep_calculations], `[[`, character(1), "name")
  )
  provider$catalog$definitions <- provider$catalog$definitions[
    !names(provider$catalog$definitions) %in% names(definitions) |
      names(provider$catalog$definitions) %in% names(definitions)[keep_definitions]
  ]
  provider$catalog$calculations <- provider$catalog$calculations[
    !names(provider$catalog$calculations) %in% names(calculations) |
      names(provider$catalog$calculations) %in% names(calculations)[keep_calculations]
  ]
  if (length(skipped)) {
    diagnostic <- new_catalog_diagnostic(
      "semantic_dependency_out_of_scope",
      sprintf(
        "Skipped associated semantic assets with dependencies outside the selection: %s.",
        paste(skipped, collapse = ", ")
      ),
      entity_id = model$id,
      details = list(skipped = skipped)
    )
    provider$catalog$diagnostics[[length(provider$catalog$diagnostics) + 1]] <- diagnostic
  }
  surface <- c(names(definitions)[keep_definitions], names(calculations)[keep_calculations])
  if (length(surface) == 0) {
    provider$catalog$models[[model$id]] <- NULL
    provider$catalog$relations[[relation_id]] <- NULL
    provider$catalog$context <- Filter(
      function(context) !model$id %in% context$scope,
      provider$catalog$context
    )
  }
  validate_commons_catalog(provider$catalog)
  invisible(provider)
}

catalog_dependencies_selected <- function(catalog, ids, selected_paths) {
  dependencies <- catalog$relations[ids]
  length(dependencies) == length(ids) && all(vapply(
    dependencies,
    function(relation) {
      catalog_source_path_key(source_path_id(relation$path)) %in% selected_paths
    },
    logical(1)
  ))
}

catalog_provider_diagnostic <- function(
  provider,
  code,
  message,
  severity = "warning",
  entity_id = NULL,
  details = list()
) {
  diagnostic <- new_catalog_diagnostic(
    code,
    message,
    severity,
    entity_id,
    details
  )
  provider$catalog$diagnostics[[length(provider$catalog$diagnostics) + 1]] <- diagnostic
  invisible(diagnostic)
}

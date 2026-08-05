databricks_connection_snapshot <- function(con) {
  row <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT current_user() AS principal,",
      "current_catalog() AS catalog_name, current_schema() AS schema_name,",
      "current_version() AS version"
    )
  )
  names(row) <- tolower(names(row))
  list(
    backend = "databricks",
    locator = list(),
    principal = row$principal[[1]],
    role = NULL,
    version = row$version[[1]],
    capabilities = list(
      describe_json = TRUE,
      unity_information_schema = !identical(
        tolower(row$catalog_name[[1]]),
        "hive_metastore"
      )
    ),
    namespace = catalog_compact(list(
      catalog = row$catalog_name[[1]],
      schema = row$schema_name[[1]]
    ))
  )
}

databricks_default_objects <- function(con, call) {
  namespace <- databricks_connection_snapshot(con)$namespace
  if (!all(c("catalog", "schema") %in% names(namespace))) {
    cli::cli_abort(
      c(
        "The Databricks connection has no current catalog and schema.",
        "i" = "Set both on the connection or supply {.arg options} with explicit {.arg include} IDs."
      ),
      call = call
    )
  }
  databricks_list_namespace(con, do.call(DBI::Id, namespace), call)
}

databricks_list_namespace <- function(con, prefix, call) {
  components <- prefix@name
  catalog <- catalog_path_component(components, "catalog")
  schema <- catalog_path_component(components, "schema")
  if (is.null(catalog)) {
    cli::cli_abort(
      "Databricks namespace selection must include a {.field catalog}.",
      call = call
    )
  }
  if (identical(tolower(catalog), "hive_metastore")) {
    return(databricks_list_hive_metastore(con, catalog, schema, call))
  }
  predicates <- c(
    paste0("table_catalog = ", DBI::dbQuoteString(con, catalog)),
    "table_schema <> 'information_schema'",
    if (!is.null(schema)) {
      paste0("table_schema = ", DBI::dbQuoteString(con, schema))
    }
  )
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT table_catalog, table_schema, table_name, table_type, comment",
        "FROM system.information_schema.tables WHERE",
        paste(predicates, collapse = " AND ")
      )
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to list Unity Catalog objects in {.val {paste(prefix@name, collapse = '.')}}.",
        parent = err,
        call = call
      )
    }
  )
  lapply(seq_len(nrow(rows)), function(i) {
    id <- DBI::Id(
      catalog = rows$table_catalog[[i]],
      schema = rows$table_schema[[i]],
      table = rows$table_name[[i]]
    )
    kind <- if (grepl("VIEW", rows$table_type[[i]], ignore.case = TRUE)) {
      "view"
    } else {
      "table"
    }
    catalog_tag_id(
      id,
      kind,
      if (!is.na(rows$comment[[i]])) rows$comment[[i]]
    )
  })
}

databricks_list_hive_metastore <- function(con, catalog, schema, call) {
  if (is.null(schema)) {
    cli::cli_abort(
      "Selecting {.val hive_metastore} requires a schema-level {.cls DBI::Id}.",
      call = call
    )
  }
  target <- DBI::Id(catalog = catalog, schema = schema)
  rows <- tryCatch(
    DBI::dbGetQuery(con, paste("SHOW TABLES IN", DBI::dbQuoteIdentifier(con, target))),
    error = function(err) {
      cli::cli_abort(
        "Failed to list hive_metastore schema {.val {schema}}.",
        parent = err,
        call = call
      )
    }
  )
  names(rows) <- tolower(names(rows))
  table_name <- rows$tablename %||% rows$table_name
  lapply(table_name, function(name) {
    catalog_tag_id(
      DBI::Id(catalog = catalog, schema = schema, table = name),
      "unknown"
    )
  })
}

databricks_import_semantics <- function(provider) {
  selected_ids <- names(provider$relation_labels)
  for (relation_id in selected_ids) {
    relation <- provider$catalog$relations[[relation_id]]
    if (!relation$kind %in% c("view", "unknown")) {
      next
    }
    specification <- databricks_read_metric_yaml(provider$con, relation$path)
    if (is.null(specification)) {
      next
    }
    if (!databricks_metric_version_supported(specification$version)) {
      diagnostic <- new_catalog_diagnostic(
        "databricks_metric_view_version",
        sprintf(
          "Metric view %s uses unsupported YAML version %s.",
          relation$name,
          specification$version
        ),
        entity_id = relation$id,
        details = list(version = specification$version)
      )
      provider$catalog$diagnostics[[length(provider$catalog$diagnostics) + 1]] <- diagnostic
      next
    }
    relation$kind <- "metric_view"
    relation$description <- specification$comment %||% relation$description
    provider$catalog$relations[[relation_id]] <- relation
    databricks_import_metric_model(provider, relation, specification)
  }
  validate_commons_catalog(provider$catalog)
  invisible(provider)
}

databricks_metric_version_supported <- function(version) {
  as.character(version) %in% c("0.1", "1.0", "1.1")
}

databricks_read_metric_yaml <- function(con, path) {
  components <- stats::setNames(path$components, path$roles)
  if (!all(c("catalog", "schema", "table") %in% names(components))) {
    return(NULL)
  }
  definition <- databricks_view_definition(
    con,
    components[["catalog"]],
    components[["schema"]],
    components[["table"]]
  )
  if (is.null(definition)) {
    metadata <- databricks_describe_json(con, path)
    definition <- metadata$view_text %||% metadata$viewText
  }
  if (is.null(definition)) {
    return(NULL)
  }
  specification <- tryCatch(
    yaml::yaml.load(definition),
    error = function(err) NULL
  )
  if (!is.list(specification) ||
      is.null(specification$version) ||
      is.null(specification$source) ||
      (is.null(specification$fields) &&
        is.null(specification$dimensions) &&
        is.null(specification$measures))) {
    return(NULL)
  }
  specification
}

databricks_describe_json <- function(con, path) {
  id <- source_path_id(path)
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

databricks_view_definition <- function(con, catalog, schema, table) {
  predicates <- paste(
    c(
      paste0("table_catalog = ", DBI::dbQuoteString(con, catalog)),
      paste0("table_schema = ", DBI::dbQuoteString(con, schema)),
      paste0("table_name = ", DBI::dbQuoteString(con, table))
    ),
    collapse = " AND "
  )
  length_row <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT length(view_definition) AS definition_length",
        "FROM system.information_schema.views WHERE",
        predicates
      )
    ),
    error = function(err) NULL
  )
  if (is.null(length_row) || nrow(length_row) == 0 || is.na(length_row[[1]][[1]])) {
    return(NULL)
  }
  length <- as.integer(length_row[[1]][[1]])
  if (length > 200000L) {
    return(NULL)
  }
  starts <- seq.int(1L, max(1L, length), by = 900L)
  expressions <- sprintf(
    "substring(view_definition, %d, 900) AS chunk_%d",
    starts,
    seq_along(starts)
  )
  row <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT",
      paste(expressions, collapse = ", "),
      "FROM system.information_schema.views WHERE",
      predicates
    )
  )
  paste(unlist(row[1, ], use.names = FALSE), collapse = "")
}

databricks_import_metric_model <- function(provider, relation, specification) {
  catalog <- provider$catalog
  source <- catalog$sources[[relation$source_id]]
  provenance <- new_catalog_provenance(
    "certified",
    source$id,
    locator = catalog_path_label(relation),
    harvested_at = Sys.time()
  )
  dataset <- databricks_metric_dataset(
    catalog,
    source,
    specification$source,
    provenance
  )
  catalog <- dataset$catalog
  dependencies <- dataset$relation_id
  joins <- databricks_flatten_joins(specification$joins %||% list())
  for (join in joins) {
    joined <- databricks_metric_dataset(
      catalog,
      source,
      join$source,
      provenance
    )
    catalog <- joined$catalog
    dependencies <- c(dependencies, joined$relation_id)
  }
  assertions <- Filter(function(join) length(join$rely) > 0, joins)
  for (join in assertions) {
    root <- catalog$relations[[dataset$relation_id]]
    root$constraints[[length(root$constraints) + 1]] <- new_catalog_constraint(
      "join_cardinality",
      character(),
      reference = join$source,
      enforcement = "asserted",
      native = join$rely,
      provenance = provenance
    )
    catalog$relations[[dataset$relation_id]] <- root
  }
  model <- new_catalog_model(
    id = catalog_id("model", relation$id),
    source_id = source$id,
    name = relation$name,
    description = specification$comment,
    datasets = unique(dependencies),
    relationships = specification$joins %||% list(),
    execution = list(
      kind = "databricks_metric_view",
      object = relation$path,
      parameters = specification$parameters %||% list()
    ),
    exposed = relation$id,
    dependencies = unique(dependencies),
    access = relation$access,
    version = as.character(specification$version),
    fingerprint = catalog_fingerprint(specification),
    provenance = provenance,
    extensions = list(databricks = specification)
  )
  catalog$models[[model$id]] <- model
  definitions <- databricks_metric_definitions(
    specification,
    model,
    relation,
    provenance
  )
  for (definition in definitions) {
    catalog$definitions[[definition$id]] <- definition
  }
  context <- databricks_metric_context(specification, model, source, provenance)
  for (record in context) {
    catalog$context[[record$id]] <- record
  }
  provider$catalog <- catalog
}

databricks_metric_dataset <- function(catalog, source, value, provenance) {
  is_query <- grepl("\\s|^select\\b", value, ignore.case = TRUE)
  parts <- if (is_query) character() else strsplit(value, ".", fixed = TRUE)[[1]]
  if (length(parts) == 3) {
    path <- new_source_path(parts, c("catalog", "schema", "table"))
    kind <- "table"
  } else {
    path <- new_source_path(
      c(model_dataset = catalog_fingerprint(value)),
      "model_dataset"
    )
    kind <- "governed_query"
  }
  existing <- Filter(
    function(relation) identical(relation$path, path),
    catalog$relations
  )
  if (length(existing)) {
    relation_id <- existing[[1]]$id
  } else {
    relation_id <- catalog_id(
      "relation",
      source$id,
      paste(path$components, collapse = ".")
    )
    catalog$relations[[relation_id]] <- new_catalog_relation(
      relation_id,
      source$id,
      path,
      kind = kind,
      access = new_catalog_access("unknown", "metric-view dependency"),
      provenance = provenance,
      extensions = list(databricks = list(source = value))
    )
  }
  list(catalog = catalog, relation_id = relation_id)
}

databricks_flatten_joins <- function(joins) {
  out <- list()
  visit <- function(join) {
    out[[length(out) + 1]] <<- join
    for (child in join$joins %||% list()) {
      visit(child)
    }
  }
  for (join in joins) {
    visit(join)
  }
  out
}

databricks_metric_definitions <- function(
  specification,
  model,
  relation,
  provenance
) {
  out <- list()
  entries <- list(
    dimension = c(specification$fields, specification$dimensions),
    metric = specification$measures
  )
  for (role in names(entries)) {
    for (item in entries[[role]] %||% list()) {
      if (is.null(item$name) || grepl("\\*", item$expr %||% "")) {
        next
      }
      definition <- new_catalog_definition(
        id = catalog_id("definition", model$id, item$name),
        model_id = model$id,
        relation_id = relation$id,
        role = role,
        name = item$name,
        label = item$display_name,
        description = item$comment,
        synonyms = unlist(item$synonyms),
        expressions = list(new_catalog_expression(
          "databricks",
          item$expr,
          item
        )),
        dependencies = model$datasets,
        native = list(definition = item),
        provenance = provenance,
        extensions = list(databricks = item)
      )
      out[[definition$id]] <- definition
    }
  }
  out
}

databricks_metric_context <- function(
  specification,
  model,
  source,
  provenance
) {
  texts <- unique(c(
    specification$comment,
    specification$ai_context,
    if (!is.null(specification$filter)) {
      paste("Model-wide filter:", specification$filter)
    }
  ))
  texts <- texts[!is.na(texts) & nzchar(texts)]
  out <- list()
  for (i in seq_along(texts)) {
    for (delivery in c("first_touch", "retrieval")) {
      context <- new_catalog_context(
        catalog_id("context", model$id, i, delivery),
        source$id,
        "metric_view_context",
        texts[[i]],
        scope = model$id,
        delivery = delivery,
        authority = list(kind = "certified"),
        provenance = provenance
      )
      out[[context$id]] <- context
    }
  }
  out
}

databricks_relation_metadata <- function(con, id) {
  rows <- DBI::dbGetQuery(
    con,
    paste("DESCRIBE TABLE", DBI::dbQuoteIdentifier(con, id))
  )
  names(rows) <- tolower(names(rows))
  rows <- rows[
    !is.na(rows$col_name) &
      nzchar(rows$col_name) &
      !startsWith(rows$col_name, "#"),
    ,
    drop = FALSE
  ]
  columns <- lapply(seq_len(nrow(rows)), function(i) {
    new_catalog_column(
      rows$col_name[[i]],
      native_type = rows$data_type[[i]],
      logical_type = rows$data_type[[i]],
      description = if ("comment" %in% names(rows) && !is.na(rows$comment[[i]])) {
        rows$comment[[i]]
      }
    )
  })
  names(columns) <- vapply(columns, `[[`, character(1), "name")
  list(
    columns = columns,
    constraints = databricks_relation_constraints(con, id),
    kind = NULL
  )
}

databricks_relation_constraints <- function(con, id) {
  components <- id@name
  if (!all(c("catalog", "schema", "table") %in% names(components)) ||
      identical(tolower(components[["catalog"]]), "hive_metastore")) {
    return(list())
  }
  predicates <- paste(
    c(
      paste0("tc.table_catalog = ", DBI::dbQuoteString(con, components[["catalog"]])),
      paste0("tc.table_schema = ", DBI::dbQuoteString(con, components[["schema"]])),
      paste0("tc.table_name = ", DBI::dbQuoteString(con, components[["table"]]))
    ),
    collapse = " AND "
  )
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT tc.constraint_name, tc.constraint_type, tc.enforced,",
        "k.column_name, k.ordinal_position",
        "FROM system.information_schema.table_constraints tc",
        "JOIN system.information_schema.key_column_usage k USING",
        "(constraint_catalog, constraint_schema, constraint_name, table_catalog, table_schema, table_name)",
        "WHERE", predicates,
        "ORDER BY tc.constraint_name, k.ordinal_position"
      )
    ),
    error = function(err) NULL
  )
  if (is.null(rows) || nrow(rows) == 0) {
    return(list())
  }
  lapply(split(rows, rows$constraint_name), function(group) {
    new_catalog_constraint(
      tolower(gsub(" ", "_", group$constraint_type[[1]])),
      group$column_name,
      enforcement = if (identical(group$enforced[[1]], "YES")) {
        "enforced"
      } else {
        "informational"
      },
      native = group
    )
  })
}

snowflake_connection_snapshot <- function(con) {
  row <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT CURRENT_USER() AS principal, CURRENT_ROLE() AS role,",
      "CURRENT_DATABASE() AS database_name, CURRENT_SCHEMA() AS schema_name,",
      "CURRENT_ACCOUNT() AS account_name"
    )
  )
  names(row) <- tolower(names(row))
  list(
    backend = "snowflake",
    locator = list(account = row$account_name[[1]]),
    principal = row$principal[[1]],
    role = row$role[[1]],
    namespace = catalog_compact(list(
      catalog = row$database_name[[1]],
      schema = row$schema_name[[1]]
    ))
  )
}

snowflake_default_objects <- function(con, call) {
  snapshot <- snowflake_connection_snapshot(con)
  namespace <- snapshot$namespace
  if (!all(c("catalog", "schema") %in% names(namespace))) {
    cli::cli_abort(
      c(
        "The Snowflake connection has no current database and schema.",
        "i" = "Set both on the connection or supply {.arg options} with explicit {.arg include} IDs."
      ),
      call = call
    )
  }
  snowflake_list_namespace(con, do.call(DBI::Id, namespace), call)
}

snowflake_list_namespace <- function(con, prefix, call) {
  components <- prefix@name
  catalog <- catalog_path_component(components, "catalog") %||%
    catalog_path_component(components, "database")
  schema <- catalog_path_component(components, "schema")
  if (is.null(catalog)) {
    cli::cli_abort(
      "Snowflake namespace selection must include a {.field catalog} (database).",
      call = call
    )
  }
  target <- if (is.null(schema)) {
    paste("IN DATABASE", DBI::dbQuoteIdentifier(con, catalog))
  } else {
    id <- DBI::Id(catalog = catalog, schema = schema)
    paste("IN SCHEMA", DBI::dbQuoteIdentifier(con, id))
  }
  commands <- c(
    table = paste("SHOW TERSE TABLES", target),
    view = paste("SHOW TERSE VIEWS", target),
    semantic_view = paste("SHOW SEMANTIC VIEWS", target)
  )
  objects <- list()
  for (kind in names(commands)) {
    rows <- tryCatch(
      DBI::dbGetQuery(con, commands[[kind]]),
      error = function(err) NULL
    )
    if (is.null(rows) || nrow(rows) == 0) {
      next
    }
    names(rows) <- tolower(names(rows))
    for (i in seq_len(nrow(rows))) {
      id <- DBI::Id(
        catalog = rows$database_name[[i]],
        schema = rows$schema_name[[i]],
        table = rows$name[[i]]
      )
      objects[[length(objects) + 1]] <- catalog_tag_id(
        id,
        kind,
        if ("comment" %in% names(rows) && !is.na(rows$comment[[i]])) {
          rows$comment[[i]]
        }
      )
    }
  }
  if (length(objects) == 0) {
    return(objects)
  }
  keys <- vapply(objects, catalog_source_path_key, character(1))
  priority <- vapply(objects, function(id) {
    match(attr(id, "commons_kind"), c("semantic_view", "view", "table"))
  }, integer(1))
  objects[order(priority)][!duplicated(keys[order(priority)])]
}

snowflake_import_semantics <- function(provider) {
  selected_ids <- names(provider$relation_labels)
  for (relation_id in selected_ids) {
    relation <- provider$catalog$relations[[relation_id]]
    if (!relation$kind %in% c("semantic_view", "unknown")) {
      next
    }
    specification <- snowflake_read_semantic_yaml(provider$con, relation$path)
    if (is.null(specification)) {
      specification <- snowflake_describe_semantic_view(
        provider$con,
        relation$path
      )
    }
    if (is.null(specification)) {
      if (identical(relation$kind, "semantic_view")) {
        relation$access <- new_catalog_access(
          "visible_only",
          "semantic metadata could not be read"
        )
        provider$catalog$relations[[relation$id]] <- relation
        catalog_provider_diagnostic(
          provider,
          "snowflake_semantic_view_unreadable",
          sprintf("Skipped semantic view %s because its metadata could not be read.", relation$name),
          entity_id = relation$id
        )
      }
      next
    }
    relation$kind <- "semantic_view"
    relation$description <- specification$description %||% relation$description
    provider$catalog$relations[[relation_id]] <- relation
    snowflake_import_semantic_model(provider, relation, specification)
  }
  snowflake_import_associated_semantics(provider)
  validate_commons_catalog(provider$catalog)
  invisible(provider)
}

snowflake_import_associated_semantics <- function(provider) {
  prefixes <- catalog_association_prefixes(provider)
  for (prefix in prefixes) {
    candidates <- snowflake_list_namespace(
      provider$con,
      prefix,
      rlang::caller_env()
    )
    candidates <- Filter(
      function(id) identical(attr(id, "commons_kind"), "semantic_view"),
      candidates
    )
    for (id in candidates) {
      relation <- catalog_add_associated_relation(
        provider,
        id,
        "semantic_view"
      )
      imported <- any(vapply(
        provider$catalog$models,
        function(model) relation$id %in% model$exposed,
        logical(1)
      ))
      if (imported) {
        next
      }
      specification <- snowflake_read_semantic_yaml(provider$con, relation$path)
      if (is.null(specification)) {
        specification <- snowflake_describe_semantic_view(
          provider$con,
          relation$path
        )
      }
      if (is.null(specification)) {
        provider$catalog$relations[[relation$id]] <- NULL
        catalog_provider_diagnostic(
          provider,
          "snowflake_associated_view_unreadable",
          sprintf("Skipped associated semantic view %s because its metadata could not be read.", relation$name),
          entity_id = relation$id
        )
        next
      }
      snowflake_import_semantic_model(provider, relation, specification)
      catalog_filter_associated_model(provider, relation$id)
    }
  }
  invisible(provider)
}

snowflake_describe_semantic_view <- function(con, path) {
  id <- source_path_id(path)
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste("DESC SEMANTIC VIEW", DBI::dbQuoteIdentifier(con, id))
    ),
    error = function(err) NULL
  )
  if (is.null(rows) || nrow(rows) == 0) {
    return(NULL)
  }
  names(rows) <- tolower(names(rows))
  specification <- list(name = catalog_id_name(id), tables = list())
  table_rows <- rows[rows$object_kind %in% "TABLE", , drop = FALSE]
  for (name in unique(table_rows$object_name)) {
    properties <- snowflake_desc_properties(
      table_rows[table_rows$object_name == name, , drop = FALSE]
    )
    table <- list(
      name = name,
      base_table = list(
        database = properties$base_table_database_name,
        schema = properties$base_table_schema_name,
        table = properties$base_table_name
      ),
      primary_key = list(columns = snowflake_json_value(properties$primary_key))
    )
    specification$tables[[name]] <- table
  }
  kinds <- c(
    DIMENSION = "dimensions",
    TIME_DIMENSION = "time_dimensions",
    FACT = "facts",
    METRIC = "metrics",
    DERIVED_METRIC = "metrics",
    FILTER = "filters"
  )
  for (kind in names(kinds)) {
    kind_rows <- rows[rows$object_kind %in% kind, , drop = FALSE]
    groups <- split(
      kind_rows,
      paste(kind_rows$parent_entity, kind_rows$object_name, sep = "\r")
    )
    for (group in groups) {
      properties <- snowflake_desc_properties(group)
      item <- list(
        name = group$object_name[[1]],
        expr = properties$expression,
        data_type = properties$data_type,
        description = properties$comment,
        synonyms = snowflake_json_value(properties$synonyms),
        labels = snowflake_json_value(properties$labels),
        access_modifier = switch(
          properties$access_modifier %||% "PUBLIC",
          PRIVATE = "private_access",
          "public_access"
        )
      )
      parent <- group$parent_entity[[1]]
      if (is.na(parent)) {
        specification[[kinds[[kind]]]] <- c(
          specification[[kinds[[kind]]]],
          list(item)
        )
      } else {
        specification$tables[[parent]][[kinds[[kind]]]] <- c(
          specification$tables[[parent]][[kinds[[kind]]]],
          list(item)
        )
      }
    }
  }
  specification$extensions <- list(snowflake_desc = rows)
  specification
}

snowflake_desc_properties <- function(rows) {
  values <- as.list(rows$property_value)
  names(values) <- tolower(rows$property)
  values[!duplicated(names(values))]
}

snowflake_json_value <- function(value) {
  if (is.null(value) || is.na(value)) {
    return(NULL)
  }
  tryCatch(
    jsonlite::fromJSON(value, simplifyVector = TRUE),
    error = function(err) value
  )
}

snowflake_relation_metadata <- function(con, id) {
  quoted <- DBI::dbQuoteIdentifier(con, id)
  rows <- DBI::dbGetQuery(con, paste("DESC TABLE", quoted))
  names(rows) <- tolower(names(rows))
  rows <- rows[toupper(rows$kind) == "COLUMN", , drop = FALSE]
  columns <- lapply(seq_len(nrow(rows)), function(i) {
    restrictions <- snowflake_column_restrictions(rows[i, , drop = FALSE])
    new_catalog_column(
      name = rows$name[[i]],
      native_type = rows$type[[i]],
      logical_type = rows$type[[i]],
      nullable = if ("null?" %in% names(rows)) rows[["null?"]][[i]] == "Y" else NULL,
      description = if ("comment" %in% names(rows) && !is.na(rows$comment[[i]])) {
        rows$comment[[i]]
      },
      display = if (length(restrictions)) "restricted",
      restrictions = restrictions,
      extensions = list(snowflake = as.list(rows[i, , drop = FALSE]))
    )
  })
  names(columns) <- vapply(columns, `[[`, character(1), "name")
  properties <- snowflake_constraint_properties(con, id)
  constraints <- snowflake_key_constraints(properties)
  if (length(constraints) == 0) {
    constraints <- snowflake_desc_constraints(rows)
  }
  constraints <- c(
    constraints,
    snowflake_foreign_keys(con, id, properties)
  )
  list(columns = columns, constraints = constraints, kind = "table")
}

snowflake_constraint_properties <- function(con, id) {
  components <- id@name
  if (!all(c("catalog", "schema", "table") %in% names(components))) {
    return(NULL)
  }
  catalog <- components[["catalog"]]
  constraints <- DBI::Id(
    catalog = catalog,
    schema = "INFORMATION_SCHEMA",
    table = "TABLE_CONSTRAINTS"
  )
  columns <- DBI::Id(
    catalog = catalog,
    schema = "INFORMATION_SCHEMA",
    table = "KEY_COLUMN_USAGE"
  )
  sql <- paste(
    "SELECT tc.constraint_name, tc.constraint_type, tc.enforced, tc.rely,",
    "k.column_name, k.ordinal_position",
    "FROM", DBI::dbQuoteIdentifier(con, constraints), "tc",
    "JOIN", DBI::dbQuoteIdentifier(con, columns), "k",
    "ON tc.constraint_catalog = k.constraint_catalog",
    "AND tc.constraint_schema = k.constraint_schema",
    "AND tc.constraint_name = k.constraint_name",
    "AND tc.table_catalog = k.table_catalog",
    "AND tc.table_schema = k.table_schema",
    "AND tc.table_name = k.table_name",
    "WHERE tc.table_schema =", DBI::dbQuoteString(con, components[["schema"]]),
    "AND tc.table_name =", DBI::dbQuoteString(con, components[["table"]]),
    "ORDER BY tc.constraint_name, k.ordinal_position"
  )
  rows <- tryCatch(DBI::dbGetQuery(con, sql), error = function(err) NULL)
  if (!is.null(rows)) names(rows) <- tolower(names(rows))
  rows
}

snowflake_key_constraints <- function(rows) {
  if (is.null(rows) || nrow(rows) == 0) {
    return(list())
  }
  rows <- rows[rows$constraint_type != "FOREIGN KEY", , drop = FALSE]
  lapply(split(rows, rows$constraint_name), function(group) {
    new_catalog_constraint(
      tolower(gsub(" ", "_", group$constraint_type[[1]])),
      group$column_name,
      enforcement = snowflake_constraint_enforcement(group),
      native = group
    )
  })
}

snowflake_constraint_enforcement <- function(rows) {
  if (identical(rows$enforced[[1]], "YES")) {
    return("enforced")
  }
  if (identical(rows$rely[[1]], "YES")) {
    return("asserted")
  }
  "informational"
}

snowflake_column_restrictions <- function(row) {
  fields <- intersect(
    c("policy name", "privacy domain", "masking policy"),
    names(row)
  )
  fields[vapply(fields, function(field) {
    value <- row[[field]][[1]]
    !is.na(value) && nzchar(as.character(value))
  }, logical(1))]
}

snowflake_desc_constraints <- function(rows) {
  out <- list()
  fields <- c("primary key" = "primary_key", "unique key" = "unique")
  for (field in names(fields)) {
    if (!field %in% names(rows)) {
      next
    }
    columns <- rows$name[toupper(rows[[field]]) %in% "Y"]
    if (length(columns)) {
      out[[length(out) + 1]] <- new_catalog_constraint(
        fields[[field]],
        columns,
        enforcement = "informational",
        native = list(source = "DESC TABLE")
      )
    }
  }
  out
}

snowflake_foreign_keys <- function(con, id, properties = NULL) {
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste("SHOW IMPORTED KEYS IN TABLE", DBI::dbQuoteIdentifier(con, id))
    ),
    error = function(err) NULL
  )
  if (is.null(rows) || nrow(rows) == 0) {
    return(list())
  }
  names(rows) <- tolower(names(rows))
  groups <- split(rows, rows$fk_name)
  lapply(groups, function(group) {
    property <- if (!is.null(properties)) {
      properties[properties$constraint_name == group$fk_name[[1]], , drop = FALSE]
    }
    new_catalog_constraint(
      "foreign_key",
      group$fk_column_name,
      reference = list(
        path = new_source_path(
          c(
            group$pk_database_name[[1]],
            group$pk_schema_name[[1]],
            group$pk_table_name[[1]]
          ),
          c("catalog", "schema", "table")
        ),
        columns = group$pk_column_name
      ),
      enforcement = if (!is.null(property) && nrow(property)) {
        snowflake_constraint_enforcement(property)
      } else {
        "informational"
      },
      native = group
    )
  })
}

snowflake_read_semantic_yaml <- function(con, path) {
  id <- do.call(DBI::Id, as.list(stats::setNames(
    path$components,
    path$roles
  )))
  label <- as.character(DBI::dbQuoteIdentifier(con, id))
  sql <- paste0(
    "SELECT SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW(",
    DBI::dbQuoteString(con, label),
    ") AS specification"
  )
  text <- tryCatch(
    DBI::dbGetQuery(con, sql)[[1]][[1]],
    error = function(err) NULL
  )
  if (is.null(text)) {
    return(NULL)
  }
  tryCatch(yaml::yaml.load(text), error = function(err) NULL)
}

snowflake_import_semantic_model <- function(provider, relation, specification) {
  catalog <- provider$catalog
  source <- catalog$sources[[relation$source_id]]
  provenance <- new_catalog_provenance(
    "certified",
    source$id,
    locator = catalog_path_label(relation),
    harvested_at = Sys.time()
  )
  model_id <- catalog_id("model", relation$id)
  datasets <- character()
  logical_tables <- character()

  for (table in specification$tables %||% list()) {
    dataset <- snowflake_semantic_dataset(catalog, source, table, provenance)
    catalog <- dataset$catalog
    datasets <- c(datasets, dataset$relation_id)
    logical_tables[[table$name]] <- dataset$relation_id
  }

  model <- new_catalog_model(
    id = model_id,
    source_id = source$id,
    name = specification$name %||% relation$name,
    description = specification$description,
    datasets = datasets,
    relationships = specification$relationships %||% list(),
    execution = list(
      kind = "snowflake_semantic_view",
      object = relation$path,
      variables = specification$variables %||% list()
    ),
    exposed = relation$id,
    dependencies = datasets,
    access = relation$access,
    version = as.character(
      specification$version %||% specification$semantic_model_version %||% NA_character_
    ),
    fingerprint = catalog_fingerprint(specification),
    provenance = provenance,
    extensions = list(snowflake = specification)
  )
  catalog$models[[model$id]] <- model

  definitions <- snowflake_semantic_definitions(
    specification,
    model,
    relation,
    logical_tables,
    provenance
  )
  for (definition in definitions) {
    catalog$definitions[[definition$id]] <- definition
  }
  contexts <- snowflake_semantic_context(
    specification,
    model,
    source,
    provenance
  )
  for (context in contexts) {
    catalog$context[[context$id]] <- context
  }
  calculations <- snowflake_verified_calculations(
    specification,
    model,
    source,
    provenance
  )
  for (calculation in calculations) {
    catalog$calculations[[calculation$id]] <- calculation
  }
  provider$catalog <- catalog
}

snowflake_semantic_dataset <- function(catalog, source, table, provenance) {
  base <- table$base_table %||% list()
  if (all(c("database", "schema", "table") %in% names(base))) {
    path <- new_source_path(
      c(base$database, base$schema, base$table),
      c("catalog", "schema", "table")
    )
    kind <- "table"
  } else {
    path <- new_source_path(
      c(model = table$name),
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
    constraints <- if (length(table$primary_key$columns)) {
      list(new_catalog_constraint(
        "primary_key",
        unlist(table$primary_key$columns),
        enforcement = "asserted",
        native = table$primary_key,
        provenance = provenance
      ))
    } else {
      list()
    }
    catalog$relations[[relation_id]] <- new_catalog_relation(
      relation_id,
      source$id,
      path,
      kind = kind,
      name = table$name,
      description = table$description,
      synonyms = unlist(table$synonyms),
      constraints = constraints,
      access = new_catalog_access("unknown", "semantic-view dependency"),
      provenance = provenance,
      extensions = list(snowflake = table)
    )
  }
  list(catalog = catalog, relation_id = relation_id)
}

snowflake_semantic_definitions <- function(
  specification,
  model,
  relation,
  logical_tables,
  provenance
) {
  out <- list()
  roles <- c(
    dimensions = "dimension",
    time_dimensions = "time_dimension",
    facts = "fact",
    metrics = "metric",
    filters = "filter"
  )
  add <- function(item, role, parent = NULL) {
    if ("filter" %in% tolower(unlist(item$labels))) {
      role <- "filter"
    }
    visibility <- if (identical(item$access_modifier, "private_access")) {
      "private"
    } else {
      "public"
    }
    dependency <- if (is.null(parent)) {
      model$datasets
    } else {
      logical_tables[[parent]]
    }
    definition <- new_catalog_definition(
      id = catalog_id("definition", model$id, parent %||% "model", item$name),
      model_id = model$id,
      relation_id = relation$id,
      role = role,
      name = item$name,
      label = item$label,
      description = item$description,
      synonyms = unlist(item$synonyms),
      logical_type = item$data_type,
      expressions = list(new_catalog_expression(
        "snowflake",
        item$expr %||% item$name,
        item
      )),
      dependencies = dependency,
      visibility = visibility,
      native = list(parent = parent, definition = item),
      provenance = provenance,
      extensions = list(snowflake = item)
    )
    out[[definition$id]] <<- definition
  }
  for (table in specification$tables %||% list()) {
    for (field in names(roles)) {
      for (item in table[[field]] %||% list()) {
        add(item, roles[[field]], table$name)
      }
    }
  }
  for (item in specification$metrics %||% list()) {
    add(item, "metric")
  }
  out
}

snowflake_semantic_context <- function(
  specification,
  model,
  source,
  provenance
) {
  instructions <- c(
    specification$custom_instructions,
    unlist(specification$module_custom_instructions, use.names = FALSE)
  )
  instructions <- unique(unlist(instructions, use.names = FALSE))
  instructions <- instructions[!is.na(instructions) & nzchar(instructions)]
  out <- list()
  for (i in seq_along(instructions)) {
    for (delivery in c("first_touch", "retrieval")) {
      context <- new_catalog_context(
        catalog_id("context", model$id, "instruction", i, delivery),
        source$id,
        "instruction",
        instructions[[i]],
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

snowflake_verified_calculations <- function(
  specification,
  model,
  source,
  provenance
) {
  out <- list()
  for (query in specification$verified_queries %||% list()) {
    if (is.null(query$sql) || !nzchar(query$sql)) {
      next
    }
    name <- query$name %||% query$question
    calculation <- new_catalog_calculation(
      catalog_id("calculation", model$id, name),
      source$id,
      name,
      description = query$question,
      dependencies = model$id,
      execution = new_catalog_execution(
        "verified_sql",
        "snowflake",
        query$sql,
        native = query
      ),
      provenance = provenance,
      extensions = list(snowflake = query)
    )
    out[[calculation$id]] <- calculation
  }
  out
}

catalog_fingerprint <- function(x) {
  raw <- serialize(x, NULL, version = 3)
  paste0(length(raw), "-", sum(as.integer(raw) * seq_along(raw)) %% 2147483647)
}

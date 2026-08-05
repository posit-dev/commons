catalog_from_ossie <- function(
  input,
  source_id = "source:ossie",
  call = rlang::caller_env()
) {
  document <- ossie_read(input, call)
  version <- as.character(document$version %||% "")
  if (!version %in% c("0.1.1", "0.2.0.dev0")) {
    cli::cli_abort(
      "Apache Ossie version {.val {version}} is not supported.",
      call = call
    )
  }
  models <- document$semantic_model
  if (!is.list(models) || length(models) == 0) {
    cli::cli_abort(
      "An Apache Ossie document must contain at least one semantic model.",
      call = call
    )
  }
  provenance <- new_catalog_provenance("authored", source_id)
  source <- new_catalog_source(
    source_id,
    "ossie",
    label = ossie_input_label(input),
    version = version,
    provenance = provenance,
    extensions = list(ossie = list(document = document))
  )
  catalog <- new_commons_catalog(sources = list(source))
  for (raw_model in models) {
    catalog <- ossie_import_model(catalog, raw_model, source, provenance, call)
  }
  validate_commons_catalog(catalog, call)
  catalog
}

catalog_to_ossie <- function(
  catalog,
  version = "0.2.0.dev0",
  call = rlang::caller_env()
) {
  validate_commons_catalog(catalog, call)
  if (!version %in% c("0.1.1", "0.2.0.dev0")) {
    cli::cli_abort("Apache Ossie version {.val {version}} is not supported.", call = call)
  }
  source <- catalog$sources[[1]]
  document <- source$extensions$ossie$document %||% list()
  document$version <- version
  diagnostics <- list()
  exported <- lapply(catalog$models, function(model) {
    result <- ossie_export_model(catalog, model)
    diagnostics <<- c(diagnostics, result$diagnostics)
    result$model
  })
  document$semantic_model <- unname(exported)
  for (calculation in catalog$calculations) {
    diagnostics[[length(diagnostics) + 1]] <- new_catalog_diagnostic(
      "ossie_calculation_omitted",
      sprintf("Trusted calculation %s has no Apache Ossie core representation.", calculation$name),
      severity = "info",
      entity_id = calculation$id
    )
  }
  for (term in catalog$terms) {
    diagnostics[[length(diagnostics) + 1]] <- new_catalog_diagnostic(
      "ossie_term_omitted",
      sprintf("Glossary term %s has no Apache Ossie core representation.", term$name),
      severity = "info",
      entity_id = term$id
    )
  }
  for (context in catalog$context) {
    if (is.null(context$extensions$ossie) &&
        !ossie_context_representable(context, catalog)) {
      diagnostics[[length(diagnostics) + 1]] <- new_catalog_diagnostic(
        "ossie_context_omitted",
        sprintf("Context record %s is not scoped to an exported semantic model.", context$id),
        severity = "info",
        entity_id = context$id
      )
    }
  }
  structure(
    list(document = document, diagnostics = diagnostics),
    class = "commons_ossie_export"
  )
}

ossie_read <- function(input, call) {
  if (is.list(input)) {
    return(input)
  }
  if (!is.character(input) || length(input) != 1 || is.na(input) || !nzchar(input)) {
    cli::cli_abort(
      "{.arg input} must be an Apache Ossie object or one YAML or JSON path.",
      call = call
    )
  }
  if (!file.exists(input)) {
    cli::cli_abort("Apache Ossie file {.path {input}} does not exist.", call = call)
  }
  if (file.info(input)$size > 10 * 1024^2) {
    cli::cli_abort("Apache Ossie files must not exceed 10 MiB.", call = call)
  }
  if (grepl("\\.json$", input, ignore.case = TRUE)) {
    tryCatch(
      jsonlite::fromJSON(input, simplifyVector = FALSE),
      error = function(err) cli::cli_abort(
        "Could not parse Apache Ossie JSON.",
        parent = err,
        call = call
      )
    )
  } else {
    tryCatch(
      yaml::read_yaml(input),
      error = function(err) cli::cli_abort(
        "Could not parse Apache Ossie YAML.",
        parent = err,
        call = call
      )
    )
  }
}

ossie_import_model <- function(catalog, raw, source, provenance, call) {
  if (!rlang::is_string(raw$name) || !is.list(raw$datasets) ||
      length(raw$datasets) == 0) {
    cli::cli_abort(
      "Every Apache Ossie semantic model needs a name and at least one dataset.",
      call = call
    )
  }
  model_id <- catalog_id("model", source$id, raw$name)
  relation_ids <- character()
  dataset_map <- character()
  definitions <- list()
  contexts <- list()
  for (dataset in raw$datasets) {
    imported <- ossie_import_dataset(
      dataset,
      model_id,
      source,
      provenance,
      call
    )
    if (imported$relation$id %in% names(catalog$relations)) {
      cli::cli_abort(
        "Apache Ossie dataset {.val {dataset$name}} duplicates another dataset ID.",
        call = call
      )
    }
    catalog$relations[[imported$relation$id]] <- imported$relation
    relation_ids <- c(relation_ids, imported$relation$id)
    dataset_map[[dataset$name]] <- imported$relation$id
    definitions <- c(definitions, imported$definitions)
    contexts <- c(contexts, imported$context)
  }
  relationships <- ossie_validate_relationships(raw$relationships, dataset_map, call)
  model <- new_catalog_model(
    model_id,
    source$id,
    raw$name,
    description = raw$description,
    datasets = relation_ids,
    relationships = relationships,
    exposed = relation_ids,
    dependencies = relation_ids,
    version = source$version,
    fingerprint = catalog_fingerprint(raw),
    provenance = provenance,
    extensions = ossie_import_extensions(raw)
  )
  catalog$models[[model$id]] <- model
  metrics <- lapply(raw$metrics %||% list(), function(metric) {
    ossie_import_metric(metric, model, dataset_map, provenance, call)
  })
  for (definition in c(definitions, metrics)) {
    catalog$definitions[[definition$id]] <- definition
  }
  contexts <- c(
    contexts,
    ossie_ai_context_records(
      raw$ai_context,
      source$id,
      model$id,
      "ossie_model_context",
      provenance
    ),
    ossie_relationship_context(
      relationships,
      source$id,
      model$id,
      provenance
    )
  )
  for (context in contexts) {
    catalog$context[[context$id]] <- context
  }
  ossie_add_relationship_constraints(catalog, relationships, dataset_map, provenance)
}

ossie_import_dataset <- function(dataset, model_id, source, provenance, call) {
  if (!rlang::is_string(dataset$name) || !rlang::is_string(dataset$source)) {
    cli::cli_abort(
      "Every Apache Ossie dataset needs string {.field name} and {.field source} fields.",
      call = call
    )
  }
  path <- ossie_source_path(dataset$source)
  relation_id <- catalog_id("relation", model_id, dataset$name)
  definitions <- lapply(dataset$fields %||% list(), function(field) {
    ossie_import_field(field, model_id, relation_id, provenance, call)
  })
  direct <- Filter(ossie_definition_is_column, definitions)
  columns <- lapply(direct, function(definition) {
    new_catalog_column(
      definition$name,
      logical_type = ossie_to_logical_type(definition$logical_type),
      description = definition$description,
      provenance = provenance,
      extensions = list(ossie = definition$extensions$ossie)
    )
  })
  constraints <- list()
  if (length(dataset$primary_key %||% character())) {
    constraints[[length(constraints) + 1]] <- new_catalog_constraint(
      "primary_key",
      unlist(dataset$primary_key),
      enforcement = "unknown",
      provenance = provenance
    )
  }
  for (key in dataset$unique_keys %||% list()) {
    constraints[[length(constraints) + 1]] <- new_catalog_constraint(
      "unique",
      unlist(key),
      enforcement = "unknown",
      provenance = provenance
    )
  }
  context <- ossie_ai_context_records(
    dataset$ai_context,
    source$id,
    relation_id,
    "ossie_dataset_context",
    provenance
  )
  for (definition in definitions) {
    context <- c(context, ossie_ai_context_records(
      definition$extensions$ossie$ai_context,
      source$id,
      definition$id,
      "ossie_field_context",
      provenance
    ))
  }
  list(
    relation = new_catalog_relation(
      relation_id,
      source$id,
      path,
      kind = if ("model_dataset" %in% path$roles) "governed_query" else "table",
      name = dataset$name,
      description = dataset$description,
      synonyms = ossie_ai_synonyms(dataset$ai_context),
      columns = columns,
      constraints = constraints,
      access = new_catalog_access("unknown", "Apache Ossie model"),
      provenance = provenance,
      extensions = ossie_import_extensions(dataset)
    ),
    definitions = definitions,
    context = context
  )
}

ossie_import_field <- function(field, model_id, relation_id, provenance, call) {
  if (!rlang::is_string(field$name)) {
    cli::cli_abort("Every Apache Ossie field needs a string name.", call = call)
  }
  expressions <- ossie_import_expressions(field$expression, field$name, call)
  is_time <- field$dimension$is_time
  if (is.null(is_time)) {
    is_time <- field$datatype %in% c("Date", "Time", "DateTime", "DateTimeTz")
  }
  new_catalog_definition(
    catalog_id("definition", model_id, relation_id, field$name),
    model_id,
    relation_id,
    if (isTRUE(is_time)) "time_dimension" else "dimension",
    field$name,
    label = field$label,
    description = field$description,
    synonyms = ossie_ai_synonyms(field$ai_context),
    logical_type = field$datatype,
    expressions = expressions,
    dependencies = relation_id,
    provenance = provenance,
    extensions = ossie_import_extensions(field)
  )
}

ossie_import_metric <- function(metric, model, dataset_map, provenance, call) {
  if (!rlang::is_string(metric$name)) {
    cli::cli_abort("Every Apache Ossie metric needs a string name.", call = call)
  }
  expressions <- ossie_import_expressions(metric$expression, metric$name, call)
  relation_id <- ossie_metric_relation(expressions, dataset_map)
  new_catalog_definition(
    catalog_id("definition", model$id, "metric", metric$name),
    model$id,
    relation_id,
    "metric",
    metric$name,
    description = metric$description,
    synonyms = ossie_ai_synonyms(metric$ai_context),
    logical_type = metric$datatype,
    expressions = expressions,
    dependencies = model$datasets,
    provenance = provenance,
    extensions = ossie_import_extensions(metric)
  )
}

ossie_import_expressions <- function(expression, name, call) {
  dialects <- expression$dialects
  if (!is.list(dialects) || length(dialects) == 0) {
    cli::cli_abort(
      "Apache Ossie field or metric {.val {name}} needs at least one expression dialect.",
      call = call
    )
  }
  lapply(dialects, function(item) {
    if (!rlang::is_string(item$dialect) || !rlang::is_string(item$expression)) {
      cli::cli_abort(
        "Every Apache Ossie expression needs string dialect and expression fields.",
        call = call
      )
    }
    new_catalog_expression(tolower(item$dialect), item$expression, item)
  })
}

ossie_validate_relationships <- function(relationships, dataset_map, call) {
  out <- relationships %||% list()
  for (relationship in out) {
    required <- c("name", "from", "to", "from_columns", "to_columns")
    if (any(vapply(relationship[required], is.null, logical(1))) ||
        !relationship$from %in% names(dataset_map) ||
        !relationship$to %in% names(dataset_map) ||
        length(relationship$from_columns) != length(relationship$to_columns)) {
      cli::cli_abort("An Apache Ossie relationship is incomplete or refers to an unknown dataset.", call = call)
    }
  }
  out
}

ossie_add_relationship_constraints <- function(
  catalog,
  relationships,
  dataset_map,
  provenance
) {
  for (relationship in relationships) {
    relation_id <- dataset_map[[relationship$from]]
    relation <- catalog$relations[[relation_id]]
    relation$constraints[[length(relation$constraints) + 1]] <-
      new_catalog_constraint(
        "foreign_key",
        unlist(relationship$from_columns),
        reference = list(
          relation_id = dataset_map[[relationship$to]],
          columns = unlist(relationship$to_columns)
        ),
        enforcement = "unknown",
        native = relationship,
        provenance = provenance
      )
    catalog$relations[[relation_id]] <- relation
  }
  catalog
}

ossie_source_path <- function(source) {
  parts <- strsplit(source, ".", fixed = TRUE)[[1]]
  if (length(parts) == 3 && all(grepl("^[A-Za-z_][A-Za-z0-9_$]*$", parts))) {
    return(new_source_path(parts, c("catalog", "schema", "table")))
  }
  new_source_path(c(model_dataset = catalog_fingerprint(source)), "model_dataset")
}

ossie_metric_relation <- function(expressions, dataset_map) {
  sql <- paste(vapply(expressions, `[[`, character(1), "sql"), collapse = "\n")
  matches <- names(dataset_map)[vapply(names(dataset_map), function(name) {
    grepl(paste0("\\b", name, "\\s*\\."), strip_sql_literals(sql), perl = TRUE)
  }, logical(1))]
  if (length(matches) == 1) dataset_map[[matches]] else unname(dataset_map[[1]])
}

ossie_definition_is_column <- function(definition) {
  any(vapply(definition$expressions, function(expression) {
    identical(expression$sql, definition$name)
  }, logical(1)))
}

ossie_ai_context_records <- function(
  ai_context,
  source_id,
  scope,
  kind,
  provenance
) {
  if (is.null(ai_context)) return(list())
  texts <- if (is.character(ai_context)) {
    ai_context
  } else {
    c(ai_context$instructions, unlist(ai_context$examples %||% list()))
  }
  texts <- unique(texts[!is.na(texts) & nzchar(texts)])
  out <- list()
  for (i in seq_along(texts)) {
    for (delivery in c("first_touch", "retrieval")) {
      context <- new_catalog_context(
        catalog_id("context", scope, kind, i, delivery),
        source_id,
        kind,
        texts[[i]],
        scope,
        delivery,
        authority = list(kind = "authored", system = "apache_ossie"),
        provenance = provenance,
        extensions = list(ossie = ai_context)
      )
      out[[context$id]] <- context
    }
  }
  out
}

ossie_relationship_context <- function(
  relationships,
  source_id,
  model_id,
  provenance
) {
  out <- list()
  for (relationship in relationships) {
    records <- ossie_ai_context_records(
      relationship$ai_context,
      source_id,
      model_id,
      "ossie_relationship_context",
      provenance
    )
    out <- c(out, records)
  }
  out
}

ossie_import_extensions <- function(value) {
  out <- list(ossie = value)
  for (extension in value$custom_extensions %||% list()) {
    vendor <- tolower(extension$vendor_name %||% "")
    data <- ossie_extension_data(extension$data)
    if (nzchar(vendor)) out[[vendor]] <- data
  }
  out
}

ossie_extension_data <- function(data) {
  if (!is.character(data) || length(data) != 1) return(data)
  tryCatch(
    jsonlite::fromJSON(data, simplifyVector = FALSE),
    error = function(err) data
  )
}

ossie_export_model <- function(catalog, model) {
  raw <- model$extensions$ossie %||% list()
  diagnostics <- list()
  raw$name <- model$name
  raw$description <- model$description
  raw$ai_context <- ossie_export_ai_context(
    catalog,
    model$id,
    raw$ai_context
  )
  datasets <- lapply(model$datasets, function(id) {
    result <- ossie_export_dataset(catalog, model, catalog$relations[[id]])
    diagnostics <<- c(diagnostics, result$diagnostics)
    result$dataset
  })
  raw$datasets <- unname(datasets)
  raw$relationships <- model$relationships
  metrics <- Filter(
    function(definition) identical(definition$model_id, model$id) &&
      identical(definition$role, "metric"),
    catalog$definitions
  )
  metric_results <- lapply(metrics, ossie_export_definition, catalog = catalog)
  diagnostics <- c(
    diagnostics,
    unlist(lapply(metric_results, `[[`, "diagnostics"), recursive = FALSE)
  )
  raw$metrics <- unname(Filter(
    Negate(is.null),
    lapply(metric_results, `[[`, "definition")
  ))
  omitted_metrics <- metrics[vapply(
    metric_results,
    function(result) is.null(result$definition),
    logical(1)
  )]
  for (definition in omitted_metrics) {
    raw$custom_extensions <- ossie_append_extension(
      raw$custom_extensions,
      "COMMONS",
      list(definition = ossie_plain(definition))
    )
  }
  unsupported <- Filter(
    function(definition) identical(definition$model_id, model$id) &&
      !definition$role %in% c("metric", "dimension", "time_dimension"),
    catalog$definitions
  )
  for (definition in unsupported) {
    diagnostics[[length(diagnostics) + 1]] <- new_catalog_diagnostic(
      "ossie_definition_extension_only",
      sprintf("Definition %s is preserved only in a COMMONS extension.", definition$name),
      severity = "info",
      entity_id = definition$id
    )
    raw$custom_extensions <- ossie_append_extension(
      raw$custom_extensions,
      "COMMONS",
      list(definition = ossie_plain(definition))
    )
  }
  native <- Filter(Negate(is.null), model$extensions[c("snowflake", "databricks")])
  for (vendor in names(native)) {
    if (!vendor %in% ossie_extension_vendors(raw$custom_extensions)) {
      raw$custom_extensions <- ossie_append_extension(
        raw$custom_extensions,
        toupper(vendor),
        native[[vendor]]
      )
      diagnostics[[length(diagnostics) + 1]] <- new_catalog_diagnostic(
        "ossie_native_extension",
        sprintf("Model %s native execution metadata is represented as a %s extension.", model$name, toupper(vendor)),
        severity = "info",
        entity_id = model$id
      )
    }
  }
  list(model = catalog_compact(raw), diagnostics = diagnostics)
}

ossie_extension_vendors <- function(extensions) {
  tolower(vapply(extensions %||% list(), function(extension) {
    extension$vendor_name %||% ""
  }, character(1)))
}

ossie_export_dataset <- function(catalog, model, relation) {
  raw <- relation$extensions$ossie %||% list()
  raw$name <- relation$name
  raw$source <- ossie_relation_source(relation)
  raw$description <- relation$description
  raw$ai_context <- ossie_export_ai_context(
    catalog,
    relation$id,
    raw$ai_context
  )
  constraints <- relation$constraints
  primary <- Filter(function(x) x$kind == "primary_key", constraints)
  unique_keys <- Filter(function(x) x$kind == "unique", constraints)
  raw$primary_key <- if (length(primary)) primary[[1]]$columns
  raw$unique_keys <- if (length(unique_keys)) lapply(unique_keys, `[[`, "columns")
  fields <- Filter(function(definition) {
    identical(definition$model_id, model$id) &&
      identical(definition$relation_id, relation$id) &&
      definition$role %in% c("dimension", "time_dimension")
  }, catalog$definitions)
  field_results <- lapply(fields, ossie_export_definition, catalog = catalog)
  diagnostics <- unlist(
    lapply(field_results, `[[`, "diagnostics"),
    recursive = FALSE
  )
  raw$fields <- unname(Filter(
    Negate(is.null),
    lapply(field_results, `[[`, "definition")
  ))
  omitted_fields <- fields[vapply(
    field_results,
    function(result) is.null(result$definition),
    logical(1)
  )]
  for (definition in omitted_fields) {
    raw$custom_extensions <- ossie_append_extension(
      raw$custom_extensions,
      "COMMONS",
      list(definition = ossie_plain(definition))
    )
  }
  unrepresented <- Filter(function(column) {
    !column$name %in% vapply(fields, `[[`, character(1), "name")
  }, relation$columns)
  if (length(unrepresented)) {
    raw$custom_extensions <- ossie_append_extension(
      raw$custom_extensions,
      "COMMONS",
      list(columns = lapply(unrepresented, ossie_plain))
    )
    diagnostics[[length(diagnostics) + 1]] <- new_catalog_diagnostic(
      "ossie_columns_extension_only",
      sprintf("Relation %s has physical columns without semantic fields; they are preserved in a COMMONS extension.", relation$name),
      severity = "info",
      entity_id = relation$id
    )
  }
  list(dataset = catalog_compact(raw), diagnostics = diagnostics)
}

ossie_export_definition <- function(definition, catalog) {
  raw <- definition$extensions$ossie %||% list()
  supported_names <- c(
    "ansi_sql", "snowflake", "mdx", "tableau", "databricks", "maql", "bigquery"
  )
  supported <- Filter(
    function(expression) tolower(expression$dialect) %in% supported_names,
    definition$expressions
  )
  unsupported <- Filter(
    function(expression) !tolower(expression$dialect) %in% supported_names,
    definition$expressions
  )
  diagnostics <- list()
  if (length(unsupported)) {
    raw$custom_extensions <- ossie_append_extension(
      raw$custom_extensions,
      "COMMONS",
      list(expressions = lapply(unsupported, ossie_plain))
    )
    diagnostics[[1]] <- new_catalog_diagnostic(
      "ossie_expression_extension_only",
      sprintf("Definition %s has expression dialects preserved only in a COMMONS extension.", definition$name),
      severity = "info",
      entity_id = definition$id
    )
  }
  if (length(supported) == 0) {
    return(list(definition = NULL, diagnostics = diagnostics))
  }
  raw$name <- definition$name
  raw$label <- definition$label
  raw$description <- definition$description
  raw$datatype <- ossie_from_logical_type(definition$logical_type)
  raw$expression <- list(dialects = lapply(supported, function(expression) {
    list(
      dialect = toupper(expression$dialect),
      expression = expression$sql
    )
  }))
  if (definition$role %in% c("dimension", "time_dimension")) {
    raw$dimension <- list(is_time = identical(definition$role, "time_dimension"))
  }
  if (length(definition$synonyms)) {
    ai <- raw$ai_context
    if (is.character(ai)) ai <- list(instructions = ai)
    ai$synonyms <- definition$synonyms
    raw$ai_context <- ai
  }
  raw$ai_context <- ossie_export_ai_context(
    catalog,
    definition$id,
    raw$ai_context
  )
  list(definition = catalog_compact(raw), diagnostics = diagnostics)
}

ossie_export_ai_context <- function(catalog, entity_id, raw) {
  contexts <- Filter(function(context) {
    entity_id %in% context$scope &&
      !identical(context$delivery, "evaluation") &&
      is.null(context$extensions$ossie)
  }, catalog$context)
  texts <- unique(vapply(contexts, `[[`, character(1), "text"))
  if (length(texts) == 0) return(raw)
  if (is.character(raw)) raw <- list(instructions = raw)
  instructions <- unique(c(raw$instructions, texts))
  raw$instructions <- paste(instructions[nzchar(instructions)], collapse = "\n\n")
  raw
}

ossie_context_representable <- function(context, catalog) {
  if (identical(context$delivery, "evaluation")) return(FALSE)
  entities <- c(
    names(catalog$models),
    names(catalog$relations),
    names(catalog$definitions)
  )
  any(context$scope %in% entities)
}

ossie_relation_source <- function(relation) {
  source <- relation$extensions$ossie$source
  if (!is.null(source)) return(source)
  if ("model_dataset" %in% relation$path$roles) {
    return(relation$extensions$databricks$source %||%
      relation$extensions$snowflake$source %||%
      relation$name)
  }
  paste(relation$path$components, collapse = ".")
}

ossie_append_extension <- function(extensions, vendor, data) {
  c(
    extensions %||% list(),
    list(list(
      vendor_name = vendor,
      data = as.character(jsonlite::toJSON(
        data,
        auto_unbox = TRUE,
        null = "null",
        na = "null"
      ))
    ))
  )
}

ossie_plain <- function(value) {
  if (!is.list(value)) return(unname(value))
  out <- lapply(unclass(value), ossie_plain)
  names(out) <- names(value)
  out
}

ossie_ai_synonyms <- function(ai_context) {
  if (!is.list(ai_context)) return(character())
  unlist(ai_context$synonyms %||% list(), use.names = FALSE)
}

ossie_to_logical_type <- function(type) {
  switch(
    type %||% "",
    String = "string",
    Integer = "integer",
    Decimal = "number",
    Float = "number",
    Boolean = "logical",
    Date = "date",
    Time = "time",
    DateTime = "datetime",
    DateTimeTz = "datetime_tz",
    Opaque = "opaque",
    type
  )
}

ossie_from_logical_type <- function(type) {
  switch(
    tolower(type %||% ""),
    string = "String",
    integer = "Integer",
    decimal = "Decimal",
    number = "Decimal",
    float = "Float",
    logical = "Boolean",
    boolean = "Boolean",
    date = "Date",
    time = "Time",
    datetime = "DateTime",
    datetime_tz = "DateTimeTz",
    opaque = "Opaque",
    NULL
  )
}

ossie_input_label <- function(input) {
  if (is.character(input) && length(input) == 1) basename(input) else "Apache Ossie"
}

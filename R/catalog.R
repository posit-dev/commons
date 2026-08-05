catalog_from_data_dictionary <- function(
  dictionary,
  source_id = "source:data_dictionary",
  call = rlang::caller_env()
) {
  dictionary <- as_data_dictionary(dictionary, call = call)
  if (is.null(dictionary)) {
    return(new_commons_catalog())
  }

  provenance <- new_catalog_provenance("authored", source_id)
  source <- new_catalog_source(
    id = source_id,
    kind = "data_dictionary",
    label = dictionary$name,
    description = dictionary$description,
    details = dictionary$details,
    provenance = provenance,
    field_provenance = catalog_field_provenance(
      c("label", "description", "details"),
      provenance
    ),
    extensions = list(data_dictionary = list(
      name = dictionary$name,
      description = dictionary$description,
      details = dictionary$details
    ))
  )

  relations <- lapply(
    names(dictionary$tables),
    function(name) {
      catalog_relation_from_dictionary(
        name,
        dictionary$tables[[name]],
        source_id,
        provenance
      )
    }
  )
  names(relations) <- vapply(relations, `[[`, character(1), "id")

  model_id <- catalog_id("model", source_id, dictionary$name %||% "dictionary")
  model <- new_catalog_model(
    id = model_id,
    source_id = source_id,
    name = dictionary$name %||% "dictionary",
    description = dictionary$description,
    details = dictionary$details,
    datasets = names(relations),
    relationships = dictionary$relationships,
    provenance = provenance,
    field_provenance = catalog_field_provenance(
      c("name", "description", "details", "relationships"),
      provenance
    ),
    extensions = list(data_dictionary = list(
      relationships = dictionary$relationships
    ))
  )

  definitions <- unlist(
    lapply(relations, function(relation) {
      table <- dictionary$tables[[relation$name]]
      lapply(
        names(table$definitions),
        function(name) {
          catalog_definition_from_dictionary(
            name,
            table$definitions[[name]],
            model_id,
            relation$id,
            provenance
          )
        }
      )
    }),
    recursive = FALSE
  )
  if (length(definitions)) {
    names(definitions) <- vapply(definitions, `[[`, character(1), "id")
  }

  terms <- lapply(
    names(dictionary$glossary),
    function(name) {
      new_catalog_term(
        id = catalog_id("term", source_id, name),
        source_id = source_id,
        name = name,
        description = dictionary$glossary[[name]],
        provenance = provenance,
        field_provenance = catalog_field_provenance(
          c("name", "description"),
          provenance
        )
      )
    }
  )
  names(terms) <- vapply(terms, `[[`, character(1), "id")

  context <- catalog_context_from_dictionary(
    dictionary,
    source,
    relations,
    terms,
    provenance
  )

  new_commons_catalog(
    sources = list(source),
    relations = relations,
    models = list(model),
    definitions = definitions,
    terms = terms,
    context = context,
    call = call
  )
}

catalog_to_data_dictionary <- function(catalog, call = rlang::caller_env()) {
  validate_commons_catalog(catalog, call = call)
  if (length(catalog$sources) == 0) {
    return(NULL)
  }

  source <- catalog$sources[[1]]
  relations <- catalog$relations
  table_names <- vapply(relations, `[[`, character(1), "name")
  duplicated_names <- unique(table_names[duplicated(table_names)])
  if (length(duplicated_names)) {
    cli::cli_abort(
      "Catalog relations cannot be projected to a data dictionary because table names are ambiguous: {.val {duplicated_names}}.",
      call = call
    )
  }

  tables <- lapply(
    relations,
    catalog_relation_to_dictionary,
    definitions = catalog$definitions
  )
  names(tables) <- table_names

  relationships <- unlist(
    lapply(catalog$models, `[[`, "relationships"),
    use.names = FALSE,
    recursive = FALSE
  )
  glossary <- list()
  if (length(catalog$terms)) {
    glossary <- vapply(
      catalog$terms,
      function(term) term$description %||% "",
      character(1)
    )
    names(glossary) <- vapply(catalog$terms, `[[`, character(1), "name")
  }

  new_data_dictionary(
    list(
      name = source$label,
      description = source$description,
      details = source$details,
      tables = tables,
      relationships = relationships,
      glossary = glossary
    ),
    call = call
  )
}

catalog_to_runtime_dictionary <- function(
  catalog,
  relation_labels,
  call = rlang::caller_env()
) {
  validate_commons_catalog(catalog, call = call)
  relation_ids <- intersect(names(relation_labels), names(catalog$relations))
  relations <- catalog$relations[relation_ids]
  tables <- lapply(
    relations,
    catalog_relation_to_dictionary,
    definitions = catalog$definitions
  )
  names(tables) <- unname(relation_labels[relation_ids])
  glossary <- lapply(catalog$terms, `[[`, "description")
  names(glossary) <- vapply(catalog$terms, `[[`, character(1), "name")
  relationships <- unlist(
    lapply(catalog$models, `[[`, "relationships"),
    use.names = FALSE,
    recursive = FALSE
  )
  authored_source <- Filter(
    function(source) identical(source$kind, "data_dictionary"),
    catalog$sources
  )
  source <- if (length(authored_source)) {
    authored_source[[1]]
  } else {
    catalog$sources[[1]]
  }
  new_data_dictionary(
    list(
      name = source$label,
      description = source$description,
      details = source$details,
      tables = tables,
      relationships = relationships,
      glossary = glossary
    ),
    call = call
  )
}

catalog_definition_registry <- function(
  catalog,
  source = "",
  table_labels = NULL,
  call = rlang::caller_env()
) {
  validate_commons_catalog(catalog, call = call)
  rows <- list(no_definitions)
  for (definition in catalog$definitions) {
    if (identical(definition$visibility, "private")) {
      next
    }
    relation <- catalog$relations[[definition$relation_id]]
    table <- if (relation$id %in% names(table_labels)) {
      unname(table_labels[[relation$id]])
    } else {
      relation$name
    }
    expression <- catalog_primary_expression(definition$expressions)
    model <- catalog$models[[definition$model_id]]
    role <- if (identical(definition$role, "time_dimension")) {
      "dimension"
    } else {
      definition$role
    }
    rows[[length(rows) + 1]] <- data.frame(
      name = definition$name,
      table = table,
      source = source,
      type = definition$logical_type %||% NA_character_,
      role = role,
      label = definition$label %||% NA_character_,
      description = definition$description %||% NA_character_,
      details = definition$details %||% NA_character_,
      expr = expression$sql,
      expanded = expression$sql,
      execution = model$execution$kind %||% "data_dictionary",
      model_id = definition$model_id,
      definition_id = definition$id,
      native_parent = definition$native$parent %||% NA_character_
    )
  }
  list(defs = do.call(rbind, rows))
}

catalog_context_chunks <- function(catalog, call = rlang::caller_env()) {
  validate_commons_catalog(catalog, call = call)
  records <- Filter(
    function(record) identical(record$delivery, "retrieval"),
    catalog$context
  )
  unique(vapply(records, `[[`, character(1), "text"))
}

catalog_calculation_registry <- function(catalog, call = rlang::caller_env()) {
  validate_commons_catalog(catalog, call = call)
  catalog$calculations
}

new_commons_catalog <- function(
  sources = list(),
  relations = list(),
  models = list(),
  definitions = list(),
  calculations = list(),
  terms = list(),
  context = list(),
  diagnostics = list(),
  provider = NULL,
  call = rlang::caller_env()
) {
  catalog <- structure(
    list(
      sources = catalog_records(sources, "commons_catalog_source", "source", call),
      relations = catalog_records(
        relations,
        "commons_catalog_relation",
        "relation",
        call
      ),
      models = catalog_records(models, "commons_catalog_model", "model", call),
      definitions = catalog_records(
        definitions,
        "commons_catalog_definition",
        "definition",
        call
      ),
      calculations = catalog_records(
        calculations,
        "commons_catalog_calculation",
        "calculation",
        call
      ),
      terms = catalog_records(terms, "commons_catalog_term", "term", call),
      context = catalog_records(context, "commons_catalog_context", "context", call),
      diagnostics = catalog_diagnostics(diagnostics, call),
      provider = provider
    ),
    class = "commons_catalog"
  )
  validate_commons_catalog(catalog, call = call)
  catalog
}

validate_commons_catalog <- function(catalog, call = rlang::caller_env()) {
  if (!inherits(catalog, "commons_catalog")) {
    cli::cli_abort("{.arg catalog} must be a commons catalog.", call = call)
  }

  source_ids <- names(catalog$sources)
  relation_ids <- names(catalog$relations)
  model_ids <- names(catalog$models)
  entity_ids <- c(
    source_ids,
    relation_ids,
    model_ids,
    names(catalog$definitions),
    names(catalog$calculations),
    names(catalog$terms),
    names(catalog$context)
  )

  validate_catalog_references(catalog$relations, "source_id", source_ids, call)
  validate_catalog_references(catalog$models, "source_id", source_ids, call)
  validate_catalog_references(catalog$terms, "source_id", source_ids, call)
  validate_catalog_references(catalog$context, "source_id", source_ids, call)
  validate_catalog_references(catalog$calculations, "source_id", source_ids, call)
  validate_catalog_references(catalog$definitions, "model_id", model_ids, call)
  validate_catalog_references(
    catalog$definitions,
    "relation_id",
    relation_ids,
    call
  )

  for (model in catalog$models) {
    for (field in c("datasets", "exposed", "dependencies")) {
      unknown <- setdiff(model[[field]], relation_ids)
      if (length(unknown)) {
        catalog_reference_error(model$id, field, unknown, call)
      }
    }
  }
  for (definition in catalog$definitions) {
    unknown <- setdiff(definition$dependencies, entity_ids)
    if (length(unknown)) {
      catalog_reference_error(definition$id, "dependencies", unknown, call)
    }
  }
  for (record in catalog$context) {
    unknown <- setdiff(record$scope, entity_ids)
    if (length(unknown)) {
      catalog_reference_error(record$id, "scope", unknown, call)
    }
  }
  for (calculation in catalog$calculations) {
    unknown <- setdiff(calculation$dependencies, entity_ids)
    if (length(unknown)) {
      catalog_reference_error(calculation$id, "dependencies", unknown, call)
    }
  }

  invisible(catalog)
}

new_source_path <- function(
  components,
  roles = names(components),
  call = rlang::caller_env()
) {
  if (inherits(components, "Id")) {
    components <- components@name
    roles <- names(components)
  }
  if (!is.character(components) || length(components) == 0) {
    cli::cli_abort("A source path needs character components.", call = call)
  }
  if (is.null(roles) || !is.character(roles) || length(roles) != length(components)) {
    cli::cli_abort("A source path needs one role per component.", call = call)
  }
  if (anyNA(components) || any(!nzchar(components)) || anyNA(roles) || any(!nzchar(roles))) {
    cli::cli_abort("Source path components and roles must not be empty.", call = call)
  }
  if (anyDuplicated(roles)) {
    cli::cli_abort("Source path roles must be unique.", call = call)
  }
  structure(
    list(components = unname(components), roles = unname(roles)),
    class = "commons_source_path"
  )
}

new_catalog_source <- function(
  id,
  kind,
  dialect = NULL,
  label = NULL,
  description = NULL,
  details = NULL,
  locator = list(),
  selection = list(),
  principal = NULL,
  role = NULL,
  namespace = NULL,
  identifier_case = c("preserve", "upper", "lower"),
  sample_rows = 0L,
  version = NULL,
  provenance = new_catalog_provenance("unknown", id),
  field_provenance = list(),
  extensions = list()
) {
  identifier_case <- rlang::arg_match(identifier_case)
  structure(
    list(
      id = catalog_string(id, "source id"),
      kind = catalog_string(kind, "source kind"),
      dialect = dialect,
      label = prose_field(label),
      description = prose_field(description),
      details = prose_field(details),
      locator = locator,
      selection = selection,
      principal = principal,
      role = role,
      namespace = namespace,
      identifier_case = identifier_case,
      sample_rows = catalog_count(sample_rows, "sample_rows"),
      version = version,
      provenance = provenance,
      field_provenance = field_provenance,
      extensions = extensions
    ),
    class = "commons_catalog_source"
  )
}

new_catalog_relation <- function(
  id,
  source_id,
  path,
  kind = "table",
  name = utils::tail(path$components, 1),
  label = NULL,
  description = NULL,
  details = NULL,
  aliases = character(),
  tags = character(),
  synonyms = character(),
  columns = list(),
  constraints = list(),
  access = new_catalog_access(),
  version = NULL,
  provenance = new_catalog_provenance("unknown", source_id),
  field_provenance = list(),
  extensions = list()
) {
  if (!inherits(path, "commons_source_path")) {
    cli::cli_abort("A catalog relation needs a source path.")
  }
  columns <- catalog_columns(columns)
  constraints <- catalog_constraints(constraints)
  structure(
    list(
      id = catalog_string(id, "relation id"),
      source_id = catalog_string(source_id, "relation source id"),
      path = path,
      kind = catalog_string(kind, "relation kind"),
      name = catalog_string(name, "relation name"),
      label = prose_field(label),
      description = prose_field(description),
      details = prose_field(details),
      aliases = catalog_character(aliases),
      tags = catalog_character(tags),
      synonyms = catalog_character(synonyms),
      columns = columns,
      constraints = constraints,
      access = access,
      version = version,
      provenance = provenance,
      field_provenance = field_provenance,
      extensions = extensions
    ),
    class = "commons_catalog_relation"
  )
}

new_catalog_column <- function(
  name,
  native_type = NULL,
  logical_type = NULL,
  nullable = NULL,
  description = NULL,
  details = NULL,
  units = NULL,
  values = NULL,
  range = NULL,
  examples = NULL,
  restrictions = character(),
  tags = character(),
  provenance = NULL,
  field_provenance = list(),
  extensions = list()
) {
  structure(
    list(
      name = catalog_string(name, "column name"),
      native_type = native_type,
      logical_type = logical_type,
      nullable = nullable,
      description = prose_field(description),
      details = prose_field(details),
      units = units,
      values = values,
      range = range,
      examples = examples,
      restrictions = catalog_character(restrictions),
      tags = catalog_character(tags),
      provenance = provenance,
      field_provenance = field_provenance,
      extensions = extensions
    ),
    class = "commons_catalog_column"
  )
}

new_catalog_model <- function(
  id,
  source_id,
  name,
  label = NULL,
  description = NULL,
  details = NULL,
  datasets = character(),
  relationships = list(),
  execution = NULL,
  exposed = datasets,
  dependencies = datasets,
  access = new_catalog_access(),
  version = NULL,
  fingerprint = NULL,
  provenance = new_catalog_provenance("unknown", source_id),
  field_provenance = list(),
  extensions = list()
) {
  structure(
    list(
      id = catalog_string(id, "model id"),
      source_id = catalog_string(source_id, "model source id"),
      name = catalog_string(name, "model name"),
      label = prose_field(label),
      description = prose_field(description),
      details = prose_field(details),
      datasets = catalog_character(datasets),
      relationships = relationships,
      execution = execution,
      exposed = catalog_character(exposed),
      dependencies = catalog_character(dependencies),
      access = access,
      version = version,
      fingerprint = fingerprint,
      provenance = provenance,
      field_provenance = field_provenance,
      extensions = extensions
    ),
    class = "commons_catalog_model"
  )
}

new_catalog_definition <- function(
  id,
  model_id,
  relation_id,
  role,
  name,
  label = NULL,
  description = NULL,
  details = NULL,
  synonyms = character(),
  logical_type = NULL,
  aggregation = NULL,
  expressions = list(),
  dependencies = character(),
  visibility = c("public", "private"),
  native = list(),
  provenance = NULL,
  field_provenance = list(),
  extensions = list()
) {
  visibility <- rlang::arg_match(visibility)
  expressions <- catalog_expressions(expressions)
  structure(
    list(
      id = catalog_string(id, "definition id"),
      model_id = catalog_string(model_id, "definition model id"),
      relation_id = catalog_string(relation_id, "definition relation id"),
      role = catalog_string(role, "definition role"),
      name = catalog_string(name, "definition name"),
      label = prose_field(label),
      description = prose_field(description),
      details = prose_field(details),
      synonyms = catalog_character(synonyms),
      logical_type = logical_type,
      aggregation = aggregation,
      expressions = expressions,
      dependencies = catalog_character(dependencies),
      visibility = visibility,
      native = native,
      provenance = provenance,
      field_provenance = field_provenance,
      extensions = extensions
    ),
    class = "commons_catalog_definition"
  )
}

new_catalog_expression <- function(dialect, sql, native = list()) {
  structure(
    list(
      dialect = catalog_string(dialect, "expression dialect"),
      sql = catalog_string(sql, "expression SQL"),
      native = native
    ),
    class = "commons_catalog_expression"
  )
}

new_catalog_calculation <- function(
  id,
  source_id,
  name,
  description = NULL,
  arguments = list(),
  dependencies = character(),
  execution,
  provenance = NULL,
  field_provenance = list(),
  extensions = list()
) {
  arguments <- catalog_arguments(arguments)
  execution <- catalog_execution(execution, arguments)
  structure(
    list(
      id = catalog_string(id, "calculation id"),
      source_id = catalog_string(source_id, "calculation source id"),
      name = catalog_string(name, "calculation name"),
      description = prose_field(description),
      arguments = arguments,
      dependencies = catalog_character(dependencies),
      execution = execution,
      provenance = provenance,
      field_provenance = field_provenance,
      extensions = extensions
    ),
    class = "commons_catalog_calculation"
  )
}

new_catalog_term <- function(
  id,
  source_id,
  name,
  description,
  synonyms = character(),
  provenance = NULL,
  field_provenance = list(),
  extensions = list()
) {
  structure(
    list(
      id = catalog_string(id, "term id"),
      source_id = catalog_string(source_id, "term source id"),
      name = catalog_string(name, "term name"),
      description = prose_field(description),
      synonyms = catalog_character(synonyms),
      provenance = provenance,
      field_provenance = field_provenance,
      extensions = extensions
    ),
    class = "commons_catalog_term"
  )
}

new_catalog_context <- function(
  id,
  source_id,
  kind,
  text,
  scope = character(),
  delivery = c("ambient", "first_touch", "retrieval", "evaluation"),
  authority = list(kind = "unknown"),
  provenance = NULL,
  field_provenance = list(),
  extensions = list()
) {
  delivery <- rlang::arg_match(delivery)
  structure(
    list(
      id = catalog_string(id, "context id"),
      source_id = catalog_string(source_id, "context source id"),
      kind = catalog_string(kind, "context kind"),
      text = catalog_string(text, "context text"),
      scope = catalog_character(scope),
      delivery = delivery,
      authority = authority,
      provenance = provenance,
      field_provenance = field_provenance,
      extensions = extensions
    ),
    class = "commons_catalog_context"
  )
}

new_catalog_access <- function(
  state = c("unknown", "queryable", "visible_only"),
  evidence = NULL
) {
  state <- rlang::arg_match(state)
  structure(list(state = state, evidence = evidence), class = "commons_catalog_access")
}

new_catalog_constraint <- function(
  kind,
  columns,
  reference = NULL,
  enforcement = c("unknown", "informational", "asserted", "enforced"),
  native = list(),
  provenance = NULL
) {
  enforcement <- rlang::arg_match(enforcement)
  structure(
    list(
      kind = catalog_string(kind, "constraint kind"),
      columns = catalog_character(columns),
      reference = reference,
      enforcement = enforcement,
      native = native,
      provenance = provenance
    ),
    class = "commons_catalog_constraint"
  )
}

new_catalog_argument <- function(
  type = c("string", "integer", "number", "logical", "date", "datetime"),
  required = TRUE,
  binding = c("value", "identifier"),
  choices = NULL
) {
  type <- rlang::arg_match(type)
  binding <- rlang::arg_match(binding)
  if (!rlang::is_bool(required)) {
    cli::cli_abort("A calculation argument's {.field required} field must be true or false.")
  }
  choices <- catalog_character(choices)
  if (identical(binding, "identifier") && length(choices) == 0) {
    cli::cli_abort("Identifier calculation arguments require an explicit allowlist.")
  }
  structure(
    list(
      type = type,
      required = required,
      binding = binding,
      choices = choices
    ),
    class = "commons_catalog_argument"
  )
}

new_catalog_binding <- function(
  argument,
  method = c("parameter", "identifier"),
  token = NULL
) {
  method <- rlang::arg_match(method)
  if (!is.null(token)) {
    token <- catalog_string(token, "binding token")
  }
  if (identical(method, "identifier") && is.null(token)) {
    cli::cli_abort("Identifier execution bindings require an explicit token.")
  }
  structure(
    list(
      argument = catalog_string(argument, "binding argument"),
      method = method,
      token = token
    ),
    class = "commons_catalog_binding"
  )
}

new_catalog_execution <- function(
  kind = c("verified_sql", "parameterized_sql", "native_metric", "governed_function"),
  dialect,
  sql = NULL,
  bindings = list(),
  native = list()
) {
  kind <- rlang::arg_match(kind)
  if (!is.null(sql)) {
    sql <- catalog_string(sql, "execution SQL")
  }
  if (length(bindings)) {
    valid <- vapply(bindings, inherits, logical(1), "commons_catalog_binding")
    if (!all(valid)) {
      cli::cli_abort("Every execution binding must be a catalog binding.")
    }
  }
  structure(
    list(
      kind = kind,
      dialect = catalog_string(dialect, "execution dialect"),
      sql = sql,
      bindings = bindings,
      native = native
    ),
    class = "commons_catalog_execution"
  )
}

new_catalog_provenance <- function(
  kind = c("unknown", "authored", "certified", "discovered", "inferred"),
  source_id,
  locator = NULL,
  harvested_at = NULL
) {
  kind <- rlang::arg_match(kind)
  structure(
    list(
      kind = kind,
      source_id = source_id,
      locator = locator,
      harvested_at = harvested_at
    ),
    class = "commons_catalog_provenance"
  )
}

new_catalog_diagnostic <- function(
  code,
  message,
  severity = c("warning", "error", "info"),
  entity_id = NULL,
  details = list()
) {
  severity <- rlang::arg_match(severity)
  structure(
    list(
      code = catalog_string(code, "diagnostic code"),
      message = catalog_string(message, "diagnostic message"),
      severity = severity,
      entity_id = entity_id,
      details = details
    ),
    class = "commons_catalog_diagnostic"
  )
}

catalog_relation_from_dictionary <- function(
  name,
  table,
  source_id,
  provenance
) {
  columns <- lapply(
    names(table$columns),
    function(column_name) {
      column <- table$columns[[column_name]]
      new_catalog_column(
        name = column_name,
        native_type = column$type,
        logical_type = column$type,
        description = column$description,
        details = column$details,
        units = column$units,
        values = column$values,
        range = column$range,
        examples = column$examples,
        restrictions = unlist(column$constraints),
        provenance = provenance,
        field_provenance = catalog_field_provenance(
          names(column)[!vapply(column, is.null, logical(1))],
          provenance
        ),
        extensions = list(data_dictionary = column)
      )
    }
  )
  names(columns) <- names(table$columns)

  new_catalog_relation(
    id = catalog_id("relation", source_id, name),
    source_id = source_id,
    path = new_source_path(c(table = name)),
    name = name,
    label = table$label,
    description = table$description,
    details = table$details,
    columns = columns,
    access = new_catalog_access("unknown", "authored dictionary"),
    provenance = provenance,
    field_provenance = catalog_field_provenance(
      names(table)[!vapply(table, is.null, logical(1))],
      provenance
    ),
    extensions = list(data_dictionary = table)
  )
}

catalog_definition_from_dictionary <- function(
  name,
  definition,
  model_id,
  relation_id,
  provenance
) {
  new_catalog_definition(
    id = catalog_id("definition", relation_id, name),
    model_id = model_id,
    relation_id = relation_id,
    role = definition$role,
    name = name,
    label = definition$label,
    description = definition$description,
    details = definition$details,
    logical_type = definition$type,
    expressions = list(new_catalog_expression(
      "data_dictionary",
      definition$expanded
    )),
    native = definition,
    provenance = provenance,
    field_provenance = catalog_field_provenance(
      names(definition)[!vapply(definition, is.null, logical(1))],
      provenance
    ),
    extensions = list(data_dictionary = definition)
  )
}

catalog_context_from_dictionary <- function(
  dictionary,
  source,
  relations,
  terms,
  provenance
) {
  records <- list()
  add <- function(record) {
    records[[record$id]] <<- record
  }
  for (field in c("description", "details")) {
    text <- source[[field]]
    if (is.null(text) || !nzchar(text)) {
      next
    }
    for (delivery in c("ambient", "retrieval")) {
      add(new_catalog_context(
        id = catalog_id("context", source$id, field, delivery),
        source_id = source$id,
        kind = paste0("dataset_", field),
        text = text,
        scope = source$id,
        delivery = delivery,
        authority = list(kind = "authored"),
        provenance = provenance,
        field_provenance = catalog_field_provenance("text", provenance)
      ))
    }
  }
  for (relation in relations) {
    text <- paste(c(relation$description, relation$details), collapse = "\n\n")
    if (!nzchar(text)) {
      next
    }
    for (delivery in c("first_touch", "retrieval")) {
      add(new_catalog_context(
        id = catalog_id("context", relation$id, delivery),
        source_id = source$id,
        kind = "relation_prose",
        text = sprintf("Table `%s`: %s", relation$name, text),
        scope = relation$id,
        delivery = delivery,
        authority = list(kind = "authored"),
        provenance = provenance,
        field_provenance = catalog_field_provenance("text", provenance)
      ))
    }
  }
  for (term in terms) {
    text <- sprintf("%s: %s", term$name, term$description)
    for (delivery in c("ambient", "retrieval")) {
      add(new_catalog_context(
        id = catalog_id("context", term$id, delivery),
        source_id = source$id,
        kind = "glossary_term",
        text = text,
        scope = term$id,
        delivery = delivery,
        authority = list(kind = "authored"),
        provenance = provenance,
        field_provenance = catalog_field_provenance("text", provenance)
      ))
    }
  }
  records
}

catalog_relation_to_dictionary <- function(relation, definitions) {
  entry <- relation$extensions$data_dictionary %||% list()
  entry$label <- relation$label
  entry$description <- relation$description
  entry$details <- relation$details
  entry$columns <- lapply(relation$columns, catalog_column_to_dictionary)

  relation_definitions <- Filter(
    function(definition) identical(definition$relation_id, relation$id),
    definitions
  )
  entry$definitions <- lapply(
    relation_definitions,
    catalog_definition_to_dictionary
  )
  names(entry$definitions) <- vapply(
    relation_definitions,
    `[[`,
    character(1),
    "name"
  )
  catalog_compact(entry)
}

catalog_column_to_dictionary <- function(column) {
  out <- column$extensions$data_dictionary %||% list()
  out$type <- column$logical_type %||% column$native_type
  out$description <- column$description
  out$details <- column$details
  out$units <- column$units
  out$values <- column$values
  out$range <- column$range
  out$examples <- column$examples
  out$constraints <- if (length(column$restrictions)) column$restrictions
  catalog_compact(out)
}

catalog_definition_to_dictionary <- function(definition) {
  out <- definition$extensions$data_dictionary %||% definition$native
  expression <- catalog_primary_expression(definition$expressions)
  out$expr <- definition$native$expr %||% expression$sql
  out$type <- definition$logical_type
  out$label <- definition$label
  out$description <- definition$description
  out$details <- definition$details
  out$expanded <- NULL
  out$role <- NULL
  catalog_compact(out)
}

catalog_primary_expression <- function(expressions) {
  if (length(expressions) == 0) {
    cli::cli_abort("A projected definition has no expression.")
  }
  expressions[[1]]
}

catalog_records <- function(records, class, what, call) {
  if (length(records) == 0) {
    return(list())
  }
  if (inherits(records, class)) {
    records <- list(records)
  }
  valid <- vapply(records, inherits, logical(1), class)
  if (!all(valid)) {
    cli::cli_abort(
      "Every catalog {what} must inherit from {.cls {class}}.",
      call = call
    )
  }
  ids <- vapply(records, `[[`, character(1), "id")
  duplicated_ids <- unique(ids[duplicated(ids)])
  if (length(duplicated_ids)) {
    cli::cli_abort(
      "Catalog {what} IDs must be unique: {.val {duplicated_ids}}.",
      call = call
    )
  }
  names(records) <- ids
  records
}

catalog_columns <- function(columns) {
  if (length(columns) == 0) {
    return(list())
  }
  valid <- vapply(columns, inherits, logical(1), "commons_catalog_column")
  if (!all(valid)) {
    cli::cli_abort("Every relation column must be a catalog column.")
  }
  names(columns) <- vapply(columns, `[[`, character(1), "name")
  if (anyDuplicated(names(columns))) {
    cli::cli_abort("Column names must be unique within a relation.")
  }
  columns
}

catalog_expressions <- function(expressions) {
  if (length(expressions) == 0) {
    return(list())
  }
  valid <- vapply(
    expressions,
    inherits,
    logical(1),
    "commons_catalog_expression"
  )
  if (!all(valid)) {
    cli::cli_abort("Every definition expression must be a catalog expression.")
  }
  expressions
}

catalog_constraints <- function(constraints) {
  if (length(constraints) == 0) {
    return(list())
  }
  valid <- vapply(
    constraints,
    inherits,
    logical(1),
    "commons_catalog_constraint"
  )
  if (!all(valid)) {
    cli::cli_abort("Every relation constraint must be a catalog constraint.")
  }
  constraints
}

catalog_arguments <- function(arguments) {
  if (length(arguments) == 0) {
    return(list())
  }
  if (is.null(names(arguments)) || any(!nzchar(names(arguments))) || anyDuplicated(names(arguments))) {
    cli::cli_abort("Calculation arguments must have unique, non-empty names.")
  }
  valid <- vapply(
    arguments,
    inherits,
    logical(1),
    "commons_catalog_argument"
  )
  if (!all(valid)) {
    cli::cli_abort("Every calculation argument must be a catalog argument.")
  }
  arguments
}

catalog_execution <- function(execution, arguments) {
  if (!inherits(execution, "commons_catalog_execution")) {
    cli::cli_abort("A catalog calculation needs a catalog execution descriptor.")
  }
  bindings <- execution$bindings
  binding_names <- vapply(bindings, `[[`, character(1), "argument")
  if (anyDuplicated(binding_names)) {
    cli::cli_abort("Each calculation argument can have only one execution binding.")
  }
  unknown <- setdiff(binding_names, names(arguments))
  missing <- setdiff(names(arguments), binding_names)
  if (length(unknown) || length(missing)) {
    cli::cli_abort(c(
      "Execution bindings must correspond exactly to calculation arguments.",
      "x" = if (length(unknown)) "Unknown bindings: {.val {unknown}}.",
      "x" = if (length(missing)) "Missing bindings: {.val {missing}}."
    ))
  }
  for (binding in bindings) {
    argument <- arguments[[binding$argument]]
    expected <- if (identical(argument$binding, "identifier")) {
      "identifier"
    } else {
      "parameter"
    }
    if (!identical(binding$method, expected)) {
      cli::cli_abort(
        "Calculation argument {.val {binding$argument}} requires a {.val {expected}} binding."
      )
    }
  }
  execution
}

catalog_diagnostics <- function(diagnostics, call) {
  if (length(diagnostics) == 0) {
    return(list())
  }
  valid <- vapply(
    diagnostics,
    inherits,
    logical(1),
    "commons_catalog_diagnostic"
  )
  if (!all(valid)) {
    cli::cli_abort(
      "Every catalog diagnostic must be a catalog diagnostic.",
      call = call
    )
  }
  diagnostics
}

validate_catalog_references <- function(records, field, valid, call) {
  for (record in records) {
    value <- record[[field]]
    if (!value %in% valid) {
      catalog_reference_error(record$id, field, value, call)
    }
  }
}

catalog_reference_error <- function(id, field, unknown, call) {
  cli::cli_abort(
    "Catalog entity {.val {id}} has unknown {.field {field}} reference{?s}: {.val {unknown}}.",
    call = call
  )
}

catalog_string <- function(x, what) {
  if (!rlang::is_string(x) || !nzchar(x)) {
    cli::cli_abort("A catalog {what} must be one non-empty string.")
  }
  x
}

catalog_character <- function(x) {
  if (is.null(x)) {
    return(character())
  }
  if (!is.character(x) || anyNA(x)) {
    cli::cli_abort("Catalog string collections must be character vectors without missing values.")
  }
  unique(x[nzchar(x)])
}

catalog_count <- function(x, what) {
  if (!is.numeric(x) || length(x) != 1 || is.na(x) || x < 0 || x != as.integer(x)) {
    cli::cli_abort("Catalog {what} must be one non-negative integer.")
  }
  as.integer(x)
}

catalog_id <- function(kind, ...) {
  components <- c(kind, unlist(list(...), use.names = FALSE))
  encoded <- vapply(
    as.character(components),
    utils::URLencode,
    character(1),
    reserved = TRUE
  )
  paste(encoded, collapse = ":")
}

catalog_compact <- function(x) {
  x[!vapply(x, is.null, logical(1))]
}

catalog_field_provenance <- function(fields, provenance) {
  fields <- unique(fields[nzchar(fields)])
  stats::setNames(rep(list(provenance), length(fields)), fields)
}

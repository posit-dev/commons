#' Configure a Databricks Genie Agent
#'
#' @param id The Genie Agent ID.
#' @param workspace An optional Databricks workspace URL. When omitted,
#'   `DATABRICKS_HOST` or the selected Databricks CLI profile supplies it.
#' @param profile An optional Databricks CLI profile. Profile credentials remain
#'   in the CLI credential store and are not retained by commons.
#'
#' @return A configuration object for the `genie` argument of
#'   [data_source_options()].
#' @export
genie_agent <- function(id, workspace = NULL, profile = NULL) {
  if (!is.character(id) || length(id) != 1 || is.na(id) ||
      !grepl("^[[:xdigit:]]{32}$", id)) {
    cli::cli_abort("{.arg id} must be a 32-character Genie Agent ID.")
  }
  workspace <- genie_optional_string(workspace, "workspace")
  profile <- genie_optional_string(profile, "profile")
  if (!is.null(workspace)) {
    workspace <- sub("/+$", "", workspace)
    if (!grepl("^https://", workspace)) {
      cli::cli_abort("{.arg workspace} must be an HTTPS URL.")
    }
  }
  structure(
    list(id = tolower(id), workspace = workspace, profile = profile),
    class = "commons_genie_agent"
  )
}

genie_import <- function(provider, config, fetch = genie_fetch) {
  fetched <- fetch(config)
  specification <- genie_parse_serialized(fetched$response$serialized_space)
  catalog <- provider$catalog
  source <- catalog$sources[[1]]
  provenance <- new_catalog_provenance(
    "authored",
    source$id,
    locator = paste0("genie:", config$id),
    harvested_at = Sys.time()
  )
  scope <- genie_import_assets(provider, specification, provenance)
  catalog <- provider$catalog
  source <- catalog$sources[[1]]
  source$extensions$genie[[config$id]] <- list(
    id = config$id,
    title = fetched$response$title %||% fetched$response$display_name,
    warehouse_id = fetched$response$warehouse_id,
    etag = fetched$response$etag,
    serialized_version = specification$version,
    fingerprint = catalog_fingerprint(specification),
    retrieval_principal = fetched$principal,
    configuration_principal = genie_configuration_principal(fetched$response)
  )
  catalog$sources[[source$id]] <- source
  provider$catalog <- catalog
  genie_reconcile_identity(provider, fetched, config)
  if (length(scope) == 0) {
    catalog_provider_diagnostic(
      provider,
      "genie_scope_empty",
      "The Genie Agent has no data sources inside this data-source selection.",
      details = list(agent_id = config$id)
    )
    validate_commons_catalog(provider$catalog)
    return(invisible(provider))
  }

  model <- genie_model(provider, specification, scope, provenance, config$id)
  provider$catalog$models[[model$id]] <- model
  genie_import_instructions(provider, specification, model, provenance, config$id)
  genie_import_benchmarks(provider, specification, model, provenance, config$id)
  validate_commons_catalog(provider$catalog)
  invisible(provider)
}

genie_fetch <- function(config) {
  if (!is.null(config$profile)) {
    return(genie_fetch_cli(config))
  }
  genie_fetch_rest(config)
}

genie_fetch_cli <- function(config) {
  cli_path <- Sys.which("databricks")
  if (!nzchar(cli_path)) {
    cli::cli_abort(
      "The Databricks CLI is required to use a {.arg profile} for Genie import."
    )
  }
  endpoint <- sprintf(
    "/api/2.0/genie/spaces/%s?include_serialized_space=true",
    config$id
  )
  response <- genie_cli_json(
    cli_path,
    c("api", "get", endpoint, "--profile", config$profile, "--output", "json"),
    "fetch the Genie Agent"
  )
  principal <- genie_cli_json(
    cli_path,
    c("current-user", "me", "--profile", config$profile, "--output", "json"),
    "read the Databricks profile identity"
  )
  principal <- principal$user_name %||% principal$userName
  list(response = response, principal = principal)
}

genie_cli_json <- function(command, args, action) {
  result <- processx::run(command, args, error_on_status = FALSE)
  if (result$status != 0) {
    cli::cli_abort(
      "Could not {action}.",
      parent = simpleError(trimws(result$stderr))
    )
  }
  tryCatch(
    jsonlite::fromJSON(result$stdout, simplifyVector = FALSE),
    error = function(err) cli::cli_abort(
      "Databricks returned invalid JSON while trying to {action}.",
      parent = err
    )
  )
}

genie_fetch_rest <- function(config) {
  workspace <- config$workspace %||% Sys.getenv("DATABRICKS_HOST", unset = NA)
  token <- Sys.getenv("DATABRICKS_TOKEN", unset = NA)
  if (is.na(workspace) || !nzchar(workspace) || is.na(token) || !nzchar(token)) {
    cli::cli_abort(c(
      "Genie import needs Databricks REST credentials.",
      "i" = "Supply {.arg profile}, or set {.envvar DATABRICKS_HOST} and {.envvar DATABRICKS_TOKEN}."
    ))
  }
  workspace <- sub("/+$", "", workspace)
  agent_url <- sprintf("%s/api/2.0/genie/spaces/%s", workspace, config$id)
  response <- genie_perform(
    httr2::request(agent_url) |>
      httr2::req_url_query(include_serialized_space = "true") |>
      httr2::req_auth_bearer_token(token),
    "fetch the Genie Agent"
  )
  identity <- genie_perform(
    httr2::request(paste0(workspace, "/api/2.0/preview/scim/v2/Me")) |>
      httr2::req_auth_bearer_token(token),
    "read the Databricks REST identity"
  )
  list(
    response = httr2::resp_body_json(response, simplifyVector = FALSE),
    principal = httr2::resp_body_json(identity, simplifyVector = FALSE)$userName
  )
}

genie_perform <- function(request, action) {
  tryCatch(
    httr2::req_perform(request),
    error = function(err) cli::cli_abort(
      "Could not {action}. Confirm that this identity can edit the Genie Agent.",
      parent = err
    )
  )
}

genie_parse_serialized <- function(serialized) {
  if (!is.character(serialized) || length(serialized) != 1 || is.na(serialized)) {
    cli::cli_abort(
      "The Genie response does not contain a serialized Agent definition. Confirm that this identity can edit the Agent."
    )
  }
  if (nchar(serialized, type = "bytes") > 5 * 1024^2) {
    cli::cli_abort("The serialized Genie Agent is larger than the 5 MiB import limit.")
  }
  specification <- tryCatch(
    jsonlite::fromJSON(serialized, simplifyVector = FALSE),
    error = function(err) cli::cli_abort(
      "The serialized Genie Agent is not valid JSON.",
      parent = err
    )
  )
  genie_validate_shape(specification)
  version <- as.character(specification$version)
  if (!version %in% c("1", "2")) {
    cli::cli_abort("Genie serialized version {.val {version}} is not supported.")
  }
  specification
}

genie_validate_shape <- function(value, depth = 0L, state = new.env()) {
  state$nodes <- (state$nodes %||% 0L) + 1L
  if (depth > 40L || state$nodes > 50000L) {
    cli::cli_abort("The serialized Genie Agent exceeds the import complexity limit.")
  }
  if (is.character(value) && any(nchar(value, type = "bytes") > 250000L)) {
    cli::cli_abort("A string in the serialized Genie Agent exceeds 250 kB.")
  }
  if (is.list(value)) {
    for (item in value) {
      genie_validate_shape(item, depth + 1L, state)
    }
  }
  invisible(value)
}

genie_import_assets <- function(provider, specification, provenance) {
  data_sources <- specification$data_sources %||% list()
  assets <- c(data_sources$tables %||% list(), data_sources$metric_views %||% list())
  scope <- character()
  for (asset in assets) {
    identifier <- if (is.character(asset)) asset else asset$identifier
    relation <- genie_selected_relation(provider, identifier)
    if (is.null(relation)) {
      catalog_provider_diagnostic(
        provider,
        "genie_asset_out_of_scope",
        sprintf("Skipped Genie data source %s because it is outside the selection.", identifier %||% "<unknown>"),
        details = list(identifier = identifier)
      )
      next
    }
    scope <- c(scope, relation$id)
    if (is.list(asset)) {
      description <- genie_text(asset$description)
      if (nzchar(description)) {
        relation$description <- description
      }
      relation$synonyms <- unique(c(relation$synonyms, genie_character(asset$synonyms)))
      relation$extensions$genie <- asset
      relation <- genie_apply_column_overrides(relation)
      provider$catalog$relations[[relation$id]] <- relation
      genie_add_context(
        provider,
        "genie_data_source",
        paste0("Data source `", identifier, "`: ", description),
        relation$id,
        provenance
      )
    }
  }
  unique(scope)
}

genie_selected_relation <- function(provider, identifier) {
  if (!is.character(identifier) || length(identifier) != 1 || is.na(identifier)) {
    return(NULL)
  }
  parts <- strsplit(identifier, ".", fixed = TRUE)[[1]]
  if (length(parts) != 3 || any(!nzchar(parts))) {
    return(NULL)
  }
  selected <- provider$catalog$relations[names(provider$relation_labels)]
  matches <- Filter(function(relation) {
    identical(tolower(relation$path$components), tolower(parts))
  }, selected)
  if (length(matches) != 1) NULL else matches[[1]]
}

genie_apply_column_overrides <- function(relation) {
  configs <- relation$extensions$genie$column_configs %||% list()
  if (length(configs) == 0 || length(relation$columns) == 0) {
    return(relation)
  }
  for (config in configs) {
    name <- config$column_name %||% config$name
    index <- which(tolower(names(relation$columns)) == tolower(name %||% ""))
    if (length(index) != 1) {
      next
    }
    column <- relation$columns[[index]]
    description <- genie_text(config$description)
    if (nzchar(description)) {
      column$description <- description
    }
    if (isTRUE(config$exclude) || isTRUE(config$excluded)) {
      column$display <- "restricted"
      column$restrictions <- unique(c(column$restrictions, "excluded_by_genie"))
    }
    column$extensions$genie <- config
    relation$columns[[index]] <- column
  }
  relation
}

genie_model <- function(provider, specification, scope, provenance, agent_id) {
  source <- provider$catalog$sources[[1]]
  title <- specification$title %||% paste("Genie Agent", agent_id)
  new_catalog_model(
    id = catalog_id("model", source$id, "genie", agent_id),
    source_id = source$id,
    name = title,
    datasets = scope,
    relationships = specification$instructions$join_specs %||% list(),
    exposed = scope,
    dependencies = scope,
    version = as.character(specification$version),
    fingerprint = catalog_fingerprint(specification),
    provenance = provenance,
    extensions = list(genie = specification)
  )
}

genie_import_instructions <- function(
  provider,
  specification,
  model,
  provenance,
  agent_id
) {
  instructions <- specification$instructions %||% list()
  for (entry in instructions$text_instructions %||% list()) {
    genie_add_context(
      provider,
      "genie_instruction",
      genie_text(entry$content %||% entry),
      model$id,
      provenance
    )
  }
  for (entry in instructions$join_specs %||% list()) {
    genie_add_context(
      provider,
      "genie_join",
      genie_join_text(entry),
      model$id,
      provenance
    )
  }
  for (entry in instructions$example_question_sqls %||% list()) {
    genie_import_example(provider, entry, model, provenance)
  }
  for (entry in instructions$sample_questions %||% list()) {
    genie_add_context(
      provider,
      "genie_sample_question",
      genie_text(entry$question %||% entry),
      model$id,
      provenance
    )
  }
  genie_import_snippets(provider, instructions$sql_snippets, model, provenance)
  genie_import_functions(
    provider,
    instructions$sql_functions %||% list(),
    model,
    provenance,
    agent_id
  )
}

genie_import_example <- function(provider, entry, model, provenance) {
  question <- genie_text(entry$question %||% entry$display_name)
  sql <- genie_text(entry$sql)
  text <- paste(c(
    if (nzchar(question)) paste("Question:", question),
    if (nzchar(sql)) paste("Example SQL:", sql)
  ), collapse = "\n")
  genie_add_context(
    provider,
    "genie_example_query",
    text,
    model$id,
    provenance
  )
  parameters <- entry$parameters %||% list()
  if (length(parameters) == 0 || !nzchar(sql)) {
    return(invisible(NULL))
  }
  calculation <- genie_parameterized_calculation(
    provider,
    entry,
    model,
    provenance
  )
  if (inherits(calculation, "commons_catalog_calculation")) {
    provider$catalog$calculations[[calculation$id]] <- calculation
  }
  invisible(calculation)
}

genie_parameterized_calculation <- function(provider, entry, model, provenance) {
  sql <- genie_text(entry$sql)
  dependencies <- genie_query_dependencies(sql, provider)
  if (is.null(dependencies)) {
    catalog_provider_diagnostic(
      provider,
      "genie_query_scope_unknown",
      "Kept a parameterized Genie example as context because its table dependencies could not be confined to the selection.",
      entity_id = model$id
    )
    return(NULL)
  }
  arguments <- list()
  bindings <- list()
  prepared <- sql
  for (i in seq_along(entry$parameters)) {
    parameter <- entry$parameters[[i]]
    name <- parameter$name
    type <- genie_argument_type(parameter$type_hint %||% parameter$type)
    if (is.null(type) || !is.character(name) || length(name) != 1 ||
        !grepl("^[A-Za-z_][A-Za-z0-9_]*$", name)) {
      catalog_provider_diagnostic(
        provider,
        "genie_parameter_unsupported",
        "Kept a parameterized Genie example as context because one parameter has an unsupported name or type.",
        entity_id = model$id
      )
      return(NULL)
    }
    default <- genie_parameter_default(parameter, type)
    token <- sprintf("{{commons_genie_%s_%s}}", i, name)
    prepared <- genie_replace_parameter(prepared, name, token)
    if (lengths(regmatches(prepared, gregexpr(token, prepared, fixed = TRUE))) != 1) {
      catalog_provider_diagnostic(
        provider,
        "genie_parameter_occurrence",
        sprintf("Kept a Genie example as context because parameter %s must occur exactly once.", name),
        entity_id = model$id
      )
      return(NULL)
    }
    arguments[[name]] <- new_catalog_argument(
      type,
      required = is.null(default),
      default = default
    )
    bindings[[length(bindings) + 1]] <- new_catalog_binding(name, token = token)
  }
  name <- genie_calculation_name(entry$name %||% entry$question %||% entry$id)
  new_catalog_calculation(
    catalog_id("calculation", model$id, name),
    model$source_id,
    name,
    description = genie_text(entry$question %||% entry$description),
    arguments = arguments,
    dependencies = unique(c(model$id, dependencies)),
    execution = new_catalog_execution(
      "parameterized_sql",
      "databricks",
      prepared,
      bindings = bindings,
      native = entry
    ),
    provenance = provenance,
    extensions = list(genie = entry)
  )
}

genie_query_dependencies <- function(sql, provider) {
  clean <- strip_sql_literals(sql)
  pattern <- "(?i)\\b(?:from|join)\\s+((?:`[^`]+`|[A-Za-z_][A-Za-z0-9_$]*)(?:\\.(?:`[^`]+`|[A-Za-z_][A-Za-z0-9_$]*)){0,2})"
  matches <- regmatches(clean, gregexpr(pattern, clean, perl = TRUE))[[1]]
  if (length(matches) == 0 || identical(matches, "")) {
    return(NULL)
  }
  identifiers <- sub("(?i)^\\s*(?:from|join)\\s+", "", matches, perl = TRUE)
  ctes <- regmatches(clean, gregexpr("(?i)(?:\\bwith|,)\\s*([A-Za-z_][A-Za-z0-9_$]*)\\s+as\\s*\\(", clean, perl = TRUE))[[1]]
  ctes <- sub("(?i)^(?:\\s*with|,)\\s*([A-Za-z_][A-Za-z0-9_$]*).*", "\\1", ctes, perl = TRUE)
  identifiers <- identifiers[!tolower(identifiers) %in% tolower(ctes)]
  if (length(identifiers) == 0) {
    return(NULL)
  }
  relation_ids <- vapply(identifiers, function(identifier) {
    parts <- gsub("`", "", strsplit(identifier, ".", fixed = TRUE)[[1]], fixed = TRUE)
    parts <- genie_resolve_identifier(parts, provider$snapshot$namespace)
    if (length(parts) != 3) {
      return(NA_character_)
    }
    relation <- genie_selected_relation(provider, paste(parts, collapse = "."))
    if (is.null(relation)) NA_character_ else relation$id
  }, character(1))
  if (anyNA(relation_ids)) NULL else unique(relation_ids)
}

genie_replace_parameter <- function(sql, name, token) {
  literals <- gregexpr(sql_literal_pattern, sql, perl = TRUE)
  code <- regmatches(sql, literals, invert = TRUE)[[1]]
  pattern <- sprintf("(^|[^A-Za-z0-9_]):%s([^A-Za-z0-9_]|$)", name)
  replacement <- paste0("\\1", token, "\\2")
  regmatches(sql, literals, invert = TRUE) <-
    list(gsub(pattern, replacement, code, perl = TRUE))
  sql
}

genie_resolve_identifier <- function(parts, namespace) {
  current <- unlist(namespace, use.names = TRUE)
  if (length(parts) == 1 && all(c("catalog", "schema") %in% names(current))) {
    return(c(current[["catalog"]], current[["schema"]], parts))
  }
  if (length(parts) == 2 && "catalog" %in% names(current)) {
    return(c(current[["catalog"]], parts))
  }
  parts
}

genie_import_snippets <- function(provider, snippets, model, provenance) {
  if (is.null(snippets)) {
    return(invisible(NULL))
  }
  groups <- list(
    filter = snippets$filters,
    dimension = snippets$expressions,
    metric = snippets$measures
  )
  for (role in names(groups)) {
    for (entry in groups[[role]] %||% list()) {
      sql <- genie_text(entry$sql)
      genie_add_context(
        provider,
        paste0("genie_", role),
        paste(c(entry$display_name %||% entry$alias, sql), collapse = ": "),
        model$id,
        provenance
      )
      if (length(model$datasets) != 1 || !nzchar(sql)) {
        next
      }
      name <- entry$display_name %||% entry$alias %||% entry$id
      if (is.null(name) || !nzchar(name)) {
        next
      }
      definition <- new_catalog_definition(
        catalog_id("definition", model$id, role, name),
        model$id,
        model$datasets[[1]],
        role,
        name,
        description = genie_text(entry$comment %||% entry$instruction),
        synonyms = genie_character(entry$synonyms),
        expressions = list(new_catalog_expression("databricks", sql, entry)),
        dependencies = model$datasets,
        provenance = provenance,
        extensions = list(genie = entry)
      )
      provider$catalog$definitions[[definition$id]] <- definition
    }
  }
  if (length(model$datasets) != 1 && any(lengths(groups) > 0)) {
    catalog_provider_diagnostic(
      provider,
      "genie_snippet_relation_ambiguous",
      "Kept Genie SQL snippets as context because they do not identify one selected relation.",
      entity_id = model$id
    )
  }
  invisible(NULL)
}

genie_import_functions <- function(
  provider,
  functions,
  model,
  provenance,
  agent_id
) {
  for (entry in functions) {
    item <- if (is.character(entry)) list(identifier = entry) else entry
    identifier <- item$identifier %||% item$name
    signature <- genie_function_signature(provider$con, item)
    if (is.null(signature) || length(strsplit(identifier %||% "", ".", fixed = TRUE)[[1]]) != 3) {
      catalog_provider_diagnostic(
        provider,
        "genie_function_signature_unavailable",
        sprintf("Kept Genie SQL function %s as context because its callable signature is unavailable.", identifier %||% "<unknown>"),
        entity_id = model$id
      )
      genie_add_context(
        provider,
        "genie_sql_function",
        paste("SQL function:", identifier %||% "<unknown>"),
        model$id,
        provenance
      )
      next
    }
    arguments <- list()
    bindings <- list()
    for (parameter in signature$parameters) {
      arguments[[parameter$name]] <- new_catalog_argument(
        parameter$type,
        required = is.null(parameter$default),
        default = parameter$default
      )
      bindings[[length(bindings) + 1]] <- new_catalog_binding(parameter$name)
    }
    quoted <- as.character(DBI::dbQuoteIdentifier(
      provider$con,
      do.call(DBI::Id, as.list(stats::setNames(
        strsplit(identifier, ".", fixed = TRUE)[[1]],
        c("catalog", "schema", "table")
      )))
    ))
    placeholders <- paste(rep("?", length(arguments)), collapse = ", ")
    sql <- if (identical(signature$kind, "table")) {
      sprintf("SELECT * FROM %s(%s)", quoted, placeholders)
    } else {
      sprintf("SELECT %s(%s) AS value", quoted, placeholders)
    }
    name <- genie_calculation_name(item$display_name %||% tail(strsplit(identifier, ".", fixed = TRUE)[[1]], 1))
    calculation <- new_catalog_calculation(
      catalog_id("calculation", model$id, agent_id, name),
      model$source_id,
      name,
      description = genie_text(item$description),
      arguments = arguments,
      dependencies = model$id,
      execution = new_catalog_execution(
        "governed_function",
        "databricks",
        sql,
        bindings = bindings,
        native = item
      ),
      provenance = provenance,
      extensions = list(genie = item)
    )
    provider$catalog$calculations[[calculation$id]] <- calculation
  }
  invisible(NULL)
}

genie_function_signature <- function(con, item) {
  if (length(item$parameters %||% list())) {
    parameters <- lapply(item$parameters, genie_function_parameter)
    if (any(vapply(parameters, is.null, logical(1)))) {
      return(NULL)
    }
    return(list(
      kind = tolower(item$function_type %||% item$kind %||% "scalar"),
      parameters = parameters
    ))
  }
  identifier <- item$identifier %||% item$name
  parts <- strsplit(identifier %||% "", ".", fixed = TRUE)[[1]]
  if (length(parts) != 3) {
    return(NULL)
  }
  quoted <- as.character(DBI::dbQuoteIdentifier(
    con,
    do.call(DBI::Id, as.list(stats::setNames(parts, c("catalog", "schema", "table"))))
  ))
  report <- tryCatch(
    DBI::dbGetQuery(con, paste("DESCRIBE FUNCTION EXTENDED", quoted)),
    error = function(err) NULL
  )
  if (is.null(report) || nrow(report) == 0) {
    return(NULL)
  }
  lines <- as.character(report[[1]])
  input <- sub("^Input:\\s*", "", lines[grepl("^Input:", lines)])
  type <- sub("^Type:\\s*", "", lines[grepl("^Type:", lines)])
  parameters <- genie_parse_function_input(input[[1]] %||% "")
  if (is.null(parameters)) {
    return(NULL)
  }
  list(
    kind = if (any(grepl("table", type, ignore.case = TRUE))) "table" else "scalar",
    parameters = parameters
  )
}

genie_parse_function_input <- function(input) {
  if (!nzchar(trimws(input))) {
    return(list())
  }
  entries <- strsplit(input, ",", fixed = TRUE)[[1]]
  parameters <- lapply(entries, function(entry) {
    parts <- strsplit(trimws(entry), "\\s+")[[1]]
    if (length(parts) < 2) {
      return(NULL)
    }
    type <- genie_argument_type(parts[[2]])
    if (is.null(type)) return(NULL)
    list(name = parts[[1]], type = type, default = NULL)
  })
  if (any(vapply(parameters, is.null, logical(1)))) NULL else parameters
}

genie_function_parameter <- function(parameter) {
  type <- genie_argument_type(parameter$type_hint %||% parameter$type %||% parameter$data_type)
  name <- parameter$name
  if (is.null(type) || !is.character(name) || length(name) != 1 ||
      !grepl("^[A-Za-z_][A-Za-z0-9_]*$", name)) {
    return(NULL)
  }
  list(
    name = name,
    type = type,
    default = genie_parameter_default(parameter, type)
  )
}

genie_import_benchmarks <- function(
  provider,
  specification,
  model,
  provenance,
  agent_id
) {
  benchmarks <- specification$benchmarks %||% list()
  if (!is.null(benchmarks$questions)) benchmarks <- benchmarks$questions
  for (i in seq_along(benchmarks)) {
    entry <- benchmarks[[i]]
    text <- paste(c(
      genie_text(entry$question),
      genie_text(entry$answer$sql %||% entry$sql)
    ), collapse = "\n")
    genie_add_context(
      provider,
      "genie_benchmark",
      text,
      model$id,
      provenance,
      delivery = "evaluation",
      suffix = paste(agent_id, i)
    )
  }
  invisible(NULL)
}

genie_add_context <- function(
  provider,
  kind,
  text,
  scope,
  provenance,
  delivery = c("first_touch", "retrieval"),
  suffix = NULL
) {
  if (!is.character(text) || length(text) != 1 || is.na(text) || !nzchar(trimws(text))) {
    return(invisible(NULL))
  }
  source <- provider$catalog$sources[[1]]
  for (where in delivery) {
    context <- new_catalog_context(
      catalog_id("context", source$id, kind, catalog_fingerprint(text), suffix, where),
      source$id,
      kind,
      text,
      scope = scope,
      delivery = where,
      authority = list(kind = "authored", system = "databricks_genie"),
      provenance = provenance
    )
    provider$catalog$context[[context$id]] <- context
  }
  invisible(NULL)
}

genie_reconcile_identity <- function(provider, fetched, config) {
  execution <- provider$snapshot$principal
  retrieval <- fetched$principal
  configured <- genie_configuration_principal(fetched$response)
  identities <- Filter(
    function(value) is.character(value) && length(value) == 1 && nzchar(value),
    list(execution = execution, retrieval = retrieval, configured = configured)
  )
  if (length(unique(tolower(unlist(identities)))) > 1) {
    catalog_provider_diagnostic(
      provider,
      "genie_identity_mismatch",
      "The Genie retrieval, Agent owner, and DBI execution identities differ; warehouse grants still control execution.",
      severity = "info",
      details = c(identities, list(agent_id = config$id))
    )
  }
  invisible(NULL)
}

genie_configuration_principal <- function(response) {
  principal <- response$creator_user_name %||% response$owner_user_name
  if (is.null(principal) && grepl("^/Users/", response$parent_path %||% "")) {
    principal <- sub("^/Users/", "", response$parent_path)
  }
  principal
}

genie_join_text <- function(entry) {
  sql <- genie_text(entry$sql %||% entry$condition)
  paste(c("Join guidance", entry$left, entry$right, sql), collapse = ": ")
}

genie_argument_type <- function(type) {
  type <- toupper(as.character(type %||% ""))
  if (grepl("^(STRING|CHAR|VARCHAR)", type)) return("string")
  if (grepl("^(TINYINT|SMALLINT|INT|INTEGER)$", type)) return("integer")
  if (grepl("^(BIGINT|LONG|FLOAT|DOUBLE|REAL|DECIMAL|NUMERIC)", type)) return("number")
  if (grepl("^(BOOL|BOOLEAN)$", type)) return("logical")
  if (grepl("^DATE$", type)) return("date")
  if (grepl("^(TIMESTAMP|DATETIME)", type)) return("datetime")
  NULL
}

genie_parameter_default <- function(parameter, type) {
  value <- parameter$default
  if (is.null(value)) {
    value <- parameter$default_value$values
  }
  while (is.list(value) && length(value) == 1) {
    value <- value[[1]]
  }
  if (is.null(value)) return(NULL)
  value <- switch(
    type,
    integer = as.integer(value),
    number = as.numeric(value),
    logical = if (is.logical(value)) value else tolower(value) == "true",
    as.character(value)
  )
  if (length(value) != 1 || is.na(value)) NULL else value
}

genie_calculation_name <- function(value) {
  value <- genie_text(value)
  if (!nzchar(value)) value <- "genie_query"
  value
}

genie_text <- function(value) {
  values <- genie_character(value)
  paste(values[nzchar(values)], collapse = "\n")
}

genie_character <- function(value) {
  if (is.null(value)) return(character())
  if (is.character(value)) return(unname(value[!is.na(value)]))
  if (is.list(value)) {
    return(unlist(lapply(value, genie_character), use.names = FALSE))
  }
  as.character(value)
}

genie_optional_string <- function(value, name) {
  if (is.null(value)) return(NULL)
  if (!is.character(value) || length(value) != 1 || is.na(value) || !nzchar(value)) {
    cli::cli_abort("{.arg {name}} must be one non-empty string or null.")
  }
  value
}

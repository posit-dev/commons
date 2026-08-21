catalog_session_snapshot <- function(con, call = rlang::caller_env()) {
  if (is_snowflake_connection(con)) {
    return(snowflake_session_snapshot(con, call = call))
  }
  if (is_databricks_connection(con)) {
    return(databricks_session_snapshot(con, call = call))
  }
  NULL
}

snowflake_session_snapshot <- function(con, call = rlang::caller_env()) {
  row <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT CURRENT_USER() AS principal, CURRENT_ROLE() AS role,",
        "CURRENT_SECONDARY_ROLES() AS secondary_roles,",
        "CURRENT_DATABASE() AS catalog, CURRENT_SCHEMA() AS schema"
      )
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to read the Snowflake session identity.",
        parent = err,
        call = call
      )
    }
  )
  catalog_session_row(row, "snowflake", role = TRUE, call = call)
}

databricks_session_snapshot <- function(con, call = rlang::caller_env()) {
  row <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT CURRENT_USER() AS principal,",
        "CURRENT_CATALOG() AS catalog, CURRENT_SCHEMA() AS schema"
      )
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to read the Databricks session identity.",
        parent = err,
        call = call
      )
    }
  )
  catalog_session_row(row, "databricks", call = call)
}

catalog_session_row <- function(
  row,
  backend,
  role = FALSE,
  call = rlang::caller_env()
) {
  names(row) <- tolower(names(row))
  required <- c(
    "principal",
    if (role) c("role", "secondary_roles"),
    "catalog",
    "schema"
  )
  if (nrow(row) != 1L || !all(required %in% names(row))) {
    cli::cli_abort(
      "{backend} returned an invalid session identity response.",
      call = call
    )
  }
  list(
    backend = backend,
    principal = catalog_session_value(row$principal[[1]]),
    role = if (role) catalog_session_value(row$role[[1]]) else NULL,
    secondary_roles = if (role) {
      catalog_session_value(row$secondary_roles[[1]])
    } else {
      NULL
    },
    namespace = list(
      catalog = catalog_session_value(row$catalog[[1]]),
      schema = catalog_session_value(row$schema[[1]])
    )
  )
}

catalog_session_value <- function(value) {
  if (length(value) == 0L || is.na(value) || !nzchar(value)) {
    return(NULL)
  }
  as.character(value)
}

catalog_check_session <- function(source, call = rlang::caller_env()) {
  if (is.null(source$session)) {
    return(invisible(source))
  }
  catalog_check_session_snapshot(
    source$con,
    source$session,
    call = call
  )
  invisible(source)
}

catalog_check_session_snapshot <- function(
  con,
  snapshot,
  call = rlang::caller_env()
) {
  current <- catalog_session_snapshot(con, call = call)
  if (!identical(current, snapshot)) {
    cli::cli_abort(
      paste(
        "The connection principal, active role, or namespace changed after",
        "catalog discovery; rebuild the data source."
      ),
      class = "commons_catalog_session_changed",
      call = call
    )
  }
  invisible(snapshot)
}

catalog_probe_relation <- function(con, id) {
  catalog_probe_sql(
    con,
    paste(
      "SELECT * FROM",
      DBI::dbQuoteIdentifier(con, id),
      "WHERE 1 = 0"
    )
  )
}

catalog_probe_sql <- function(con, sql, bindings = list()) {
  tryCatch(
    {
      result <- DBI::dbSendQuery(con, sql)
      on.exit(DBI::dbClearResult(result), add = TRUE)
      if (length(bindings)) {
        DBI::dbBind(result, unname(bindings))
      }
      list(state = "queryable", error = NULL)
    },
    error = function(err) {
      list(state = catalog_access_error_kind(err), error = err)
    }
  )
}

catalog_access_error_kind <- function(err) {
  sqlstate <- toupper(as.character(
    err$sqlstate %||% err$state %||% err$parent$sqlstate %||% ""
  ))
  if (length(sqlstate) != 1L || is.na(sqlstate)) {
    sqlstate <- ""
  }
  if (
    startsWith(sqlstate, "28") ||
      identical(sqlstate, "42501") ||
      grepl(
        paste(
          "not authorized|insufficient privilege|permission denied|",
          "access denied|does not have.*privilege|not permitted|",
          "permission_denied|sql access control error",
          sep = ""
        ),
        conditionMessage(err),
        ignore.case = TRUE
      )
  ) {
    return("authorization")
  }
  if (
    startsWith(sqlstate, "08") ||
      grepl("^HYT|^40|^57P01", sqlstate) ||
      grepl(
        paste(
          "temporar|timed? ?out|unavailable|connection.*(closed|reset|failed)|",
          "warehouse.*(starting|stopped|unavailable)|throttl|rate limit|",
          "network|socket|http (429|503)|unexpected eof",
          sep = ""
        ),
        conditionMessage(err),
        ignore.case = TRUE
      )
  ) {
    return("transient")
  }
  "unknown"
}

catalog_require_queryable <- function(
  con,
  id,
  label = table_id_label(id),
  call = rlang::caller_env()
) {
  probe <- catalog_probe_relation(con, id)
  if (!identical(probe$state, "queryable")) {
    catalog_abort_access(probe, label, call = call)
  }
  invisible(id)
}

catalog_require_queryable_relations <- function(
  con,
  registry,
  relations = NULL,
  call = rlang::caller_env()
) {
  missing <- if (is.null(relations)) {
    character()
  } else {
    registry$labels[vapply(
      registry$labels,
      function(label) identical(relations[[label]]$discovered, FALSE),
      logical(1)
    )]
  }
  if (length(missing)) {
    catalog_abort_missing_relations(missing, call = call)
  }
  for (i in seq_along(registry$ids)) {
    probe <- catalog_probe_relation(con, registry$ids[[i]])
    if (identical(probe$state, "queryable")) {
      next
    }
    if (
      identical(probe$state, "unknown") &&
        identical(catalog_relation_exists(con, registry$ids[[i]]), FALSE)
    ) {
      missing <- c(missing, registry$labels[[i]])
      next
    }
    catalog_abort_access(probe, registry$labels[[i]], call = call)
  }
  if (length(missing)) {
    catalog_abort_missing_relations(missing, call = call)
  }
  invisible(registry)
}

catalog_abort_missing_relations <- function(
  missing,
  call = rlang::caller_env()
) {
  cli::cli_abort(
    "{.arg tables} names table{?s} not on the connection: {.val {missing}}.",
    call = call
  )
}

catalog_relation_exists <- function(con, id) {
  tryCatch(
    {
      exists <- DBI::dbExistsTable(con, id)
      if (length(exists) != 1L || is.na(exists)) NULL else as.logical(exists)
    },
    error = function(err) NULL
  )
}

catalog_ensure_queryable <- function(source, table, call = rlang::caller_env()) {
  manifest <- source$manifest
  if (is.null(manifest)) {
    return(invisible(source))
  }
  state <- manifest$access[[table]] %||% "unknown"
  if (identical(state, "queryable")) {
    return(invisible(source))
  }
  if (identical(state, "authorization")) {
    catalog_abort_access(
      list(state = state, error = manifest$access_errors[[table]]),
      table,
      call = call
    )
  }
  probe <- catalog_probe_relation(source$con, source$table_ids[[table]])
  if (identical(probe$state, "queryable")) {
    manifest$access[[table]] <- "queryable"
    return(invisible(source))
  }
  # Only stable authorization failures are cached; other failures retry.
  if (identical(probe$state, "authorization")) {
    manifest$access[[table]] <- probe$state
    manifest$access_errors[[table]] <- probe$error
  }
  catalog_abort_access(probe, table, call = call)
}

catalog_abort_access <- function(probe, label, call = rlang::caller_env()) {
  state <- probe$state %||% "unknown"
  message <- switch(
    state,
    authorization = "The current principal is not authorized to query {.val {label}}.",
    transient = "Query access to {.val {label}} is temporarily unavailable.",
    "Could not verify query access to {.val {label}}."
  )
  class <- switch(
    state,
    authorization = "commons_catalog_authorization_error",
    transient = "commons_catalog_transient_error",
    "commons_catalog_access_error"
  )
  cli::cli_abort(
    message,
    class = class,
    parent = probe$error,
    call = call
  )
}

catalog_validate_semantic_access <- function(
  con,
  registry,
  call = rlang::caller_env()
) {
  labels <- intersect(
    names(registry$semantic_models),
    registry$semantic_validate %||% character()
  )
  for (label in labels) {
    model <- registry$semantic_models[[label]]
    probe <- catalog_probe_semantic_model(con, model)
    if (identical(probe$state, "queryable")) {
      next
    }
    catalog_abort_access(probe, label, call = call)
  }
  registry
}

catalog_probe_semantic_model <- function(con, model) {
  bindings <- catalog_semantic_probe_bindings(model$parameters)
  sql <- catalog_semantic_probe_sql(con, model, bindings)
  if (!is.null(sql)) {
    return(catalog_probe_sql(con, sql, bindings))
  }
  if (model$backend %in% c(
    "snowflake_semantic_view",
    "databricks_metric_view"
  )) {
    return(list(
      state = "unknown",
      error = simpleError("The semantic model has no queryable public member.")
    ))
  }
  if (length(model$dependencies) == 0L) {
    return(list(
      state = "unknown",
      error = simpleError("The semantic model has no queryable public member.")
    ))
  }
  for (dependency in model$dependencies) {
    probe <- catalog_probe_relation(con, dependency)
    if (!identical(probe$state, "queryable")) {
      return(probe)
    }
  }
  list(state = "queryable", error = NULL)
}

catalog_semantic_probe_bindings <- function(parameters) {
  required <- Filter(function(parameter) !parameter$has_default, parameters)
  # Typed NULLs satisfy required signatures without inventing business values.
  values <- lapply(required, function(parameter) {
    switch(
      parameter$type,
      string = NA_character_,
      integer = NA_integer_,
      number = NA_real_,
      logical = NA,
      date = NA_character_,
      datetime = NA_character_
    )
  })
  names(values) <- vapply(required, `[[`, character(1), "name")
  values
}

catalog_semantic_probe_sql <- function(con, model, arguments = list()) {
  metric <- model$metrics[1][[1]]
  dimension <- model$dimensions[1][[1]]
  fact <- model$facts[1][[1]]
  if (identical(model$backend, "snowflake_semantic_view")) {
    member <- metric %||% dimension %||% fact
    if (is.null(member)) {
      return(NULL)
    }
    role <- if (!is.null(metric)) {
      "METRICS"
    } else if (!is.null(dimension)) {
      "DIMENSIONS"
    } else {
      "FACTS"
    }
    reference <- catalog_semantic_member_reference(con, member)
    variables <- if (length(arguments)) {
      paste0(
        "\n  VARIABLES ",
        paste(
          sprintf(
            "%s => ?",
            DBI::dbQuoteIdentifier(con, names(arguments))
          ),
          collapse = ", "
        )
      )
    } else {
      ""
    }
    return(paste0(
      "SELECT * FROM SEMANTIC_VIEW(\n  ",
      DBI::dbQuoteIdentifier(con, model$id),
      "\n  ", role, " ", reference,
      variables,
      "\n)\nLIMIT 0"
    ))
  }
  if (identical(model$backend, "databricks_metric_view")) {
    relation <- as.character(DBI::dbQuoteIdentifier(con, model$id))
    if (length(arguments)) {
      relation <- paste0(
        relation,
        "(",
        paste(
          sprintf(
            "%s => ?",
            DBI::dbQuoteIdentifier(con, names(arguments))
          ),
          collapse = ", "
        ),
        ")"
      )
    }
    if (!is.null(metric)) {
      reference <- DBI::dbQuoteIdentifier(con, metric$name)
      return(paste(
        "SELECT MEASURE(", reference, ") FROM",
        relation,
        "LIMIT 0"
      ))
    }
    if (!is.null(dimension)) {
      return(paste(
        "SELECT",
        DBI::dbQuoteIdentifier(con, dimension$name),
        "FROM",
        relation,
        "LIMIT 0"
      ))
    }
  }
  NULL
}

catalog_semantic_member_reference <- function(con, member) {
  if (is.null(member$parent) || !nzchar(member$parent)) {
    return(DBI::dbQuoteIdentifier(con, member$name))
  }
  DBI::dbQuoteIdentifier(
    con,
    DBI::Id(schema = member$parent, table = member$name)
  )
}

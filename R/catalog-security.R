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

catalog_probe_sql <- function(con, sql) {
  tryCatch(
    {
      result <- DBI::dbSendQuery(con, sql)
      on.exit(DBI::dbClearResult(result), add = TRUE)
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
  call = rlang::caller_env()
) {
  for (i in seq_along(registry$ids)) {
    catalog_require_queryable(
      con,
      registry$ids[[i]],
      registry$labels[[i]],
      call = call
    )
  }
  invisible(registry)
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

catalog_filter_semantic_access <- function(
  con,
  registry,
  call = rlang::caller_env()
) {
  keep <- rep(TRUE, length(registry$semantic_models))
  labels <- names(registry$semantic_models)
  for (i in seq_along(registry$semantic_models)) {
    model <- registry$semantic_models[[i]]
    probe <- catalog_probe_semantic_model(con, model)
    if (identical(probe$state, "queryable")) {
      next
    }
    if (
      identical(probe$state, "authorization") &&
        !labels[[i]] %in% registry$semantic_validate
    ) {
      # Hidden namespace models are safe to omit; other failures must retry.
      keep[[i]] <- FALSE
      next
    }
    catalog_abort_access(probe, labels[[i]], call = call)
  }
  registry$semantic_models <- registry$semantic_models[keep]
  registry
}

catalog_probe_semantic_model <- function(con, model) {
  sql <- catalog_semantic_probe_sql(con, model)
  if (!is.null(sql)) {
    return(catalog_probe_sql(con, sql))
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

catalog_semantic_probe_sql <- function(con, model) {
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
    return(paste0(
      "SELECT * FROM SEMANTIC_VIEW(\n  ",
      DBI::dbQuoteIdentifier(con, model$id),
      "\n  ", role, " ", reference,
      "\n)\nLIMIT 0"
    ))
  }
  if (identical(model$backend, "databricks_metric_view")) {
    if (!is.null(metric)) {
      reference <- DBI::dbQuoteIdentifier(con, metric$name)
      return(paste(
        "SELECT MEASURE(", reference, ") FROM",
        DBI::dbQuoteIdentifier(con, model$id),
        "LIMIT 0"
      ))
    }
    if (!is.null(dimension)) {
      return(paste(
        "SELECT",
        DBI::dbQuoteIdentifier(con, dimension$name),
        "FROM",
        DBI::dbQuoteIdentifier(con, model$id),
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

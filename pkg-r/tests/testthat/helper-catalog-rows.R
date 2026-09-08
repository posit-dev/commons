# Shared with the Python suite: which rows are relations, what kind each is,
# which comments count as prose, and where a DESCRIBE reply stops being
# columns. Pinned in tests/shared/catalog-rows.json rather than asserted in
# each language.
catalog_rows_frame <- function(rows) {
  columns <- unique(unlist(lapply(rows, names), use.names = FALSE))
  frame <- lapply(columns, function(column) {
    vapply(
      rows,
      function(row) {
        value <- row[[column]]
        if (is.null(value)) NA_character_ else as.character(value)
      },
      character(1)
    )
  })
  names(frame) <- columns
  as.data.frame(frame, stringsAsFactors = FALSE, check.names = FALSE)
}

catalog_rows_expect_relations <- function(relations, expected, info) {
  expect_length(relations, length(expected))
  for (i in seq_along(expected)) {
    case <- expected[[i]]
    expect_identical(
      relations[[i]]$id,
      DBI::Id(
        catalog = case$catalog,
        schema = case$schema,
        table = case$table
      ),
      info = info
    )
    expect_equal(relations[[i]]$kind, case$kind, info = info)
    if (nzchar(case$description)) {
      expect_equal(relations[[i]]$description, case$description, info = info)
    } else {
      expect_null(relations[[i]]$description, info = info)
    }
  }
}

catalog_rows_expect_columns <- function(columns, expected, info) {
  expect_equal(nrow(columns), length(expected), info = info)
  for (i in seq_along(expected)) {
    case <- expected[[i]]
    expect_equal(columns$column[[i]], case$column, info = info)
    expect_equal(columns$type[[i]], case$type, info = info)
    expect_equal(columns$nullable[[i]], case$nullable == "true", info = info)
    if (nzchar(case$description)) {
      expect_equal(columns$description[[i]], case$description, info = info)
    } else {
      expect_true(is.na(columns$description[[i]]), info = info)
    }
  }
}

# A session snapshot from the shared fixture's field-by-field spelling.
catalog_session_fixture_snapshot <- function(fields) {
  # A null case is a connection that reports no session at all.
  if (is.null(fields)) {
    return(NULL)
  }
  list(
    backend = fields$backend,
    principal = fields$principal,
    role = fields$role,
    secondary_roles = fields$secondary_roles,
    namespace = list(catalog = fields$catalog, schema = fields$schema)
  )
}

# The access-precedence fixture's relations, keyed by label.
catalog_precedence_script <- function(relations) {
  stats::setNames(relations, vapply(relations, `[[`, character(1), "label"))
}

catalog_precedence_probe <- function(state) {
  if (identical(state, "queryable")) {
    return(list(state = "queryable", error = NULL))
  }
  list(state = state, error = simpleError(state))
}

# Every refusal here is a cli condition, so the missing-relation outcome is
# told apart by what it says rather than by a class it shares with the rest.
catalog_precedence_expectation <- function(outcome) {
  switch(
    outcome,
    missing = list(class = "rlang_error", regexp = "not on the connection"),
    authorization = list(class = "commons_catalog_authorization_error"),
    transient = list(class = "commons_catalog_transient_error"),
    list(class = "commons_catalog_access_error")
  )
}

# The relations a run must have probed: every one the listing reported.
catalog_precedence_probed <- function(script) {
  names(script)[vapply(
    script,
    function(item) identical(item$discovered, "true"),
    logical(1)
  )]
}

# The relation-label fixture's authored entry, as a `tables` entry. A
# `DBI::Id` rather than a dotted string, since a case may author a name that
# contains a dot of its own.
catalog_labels_authored <- function(authored) {
  do.call(
    DBI::Id,
    c(
      if (!is.null(authored$catalog)) list(catalog = authored$catalog),
      if (!is.null(authored$schema)) list(schema = authored$schema),
      list(table = authored$table)
    )
  )
}

# The backend functions a relation-label case runs against.
catalog_labels_backends <- list(
  snowflake = list(
    current_namespace = function(...) snowflake_current_namespace(...),
    id_type = function(...) snowflake_id_type(...),
    exact_relation = function(...) snowflake_exact_relation(...)
  ),
  databricks = list(
    current_namespace = function(...) databricks_current_namespace(...),
    id_type = function(...) databricks_id_type(...),
    exact_relation = function(...) databricks_exact_relation(...)
  )
)

catalog_labels_binding <- function(case, name) {
  catalog_labels_backends[[case$backend]][[name]]
}

# The listing a relation-label case answers with. Only a Databricks
# `SHOW TABLES` reply can report a relation with no namespace of its own,
# which is what a session-scoped temporary view is.
catalog_labels_reply <- function(case) {
  function(conn, statement, ...) {
    if (grepl("CURRENT_DATABASE|CURRENT_CATALOG", statement)) {
      return(data.frame(
        CATALOG = case$namespace$catalog,
        SCHEMA = case$namespace$schema
      ))
    }
    if (identical(case$backend, "databricks")) {
      if (is.null(case$reported)) {
        return(data.frame(
          database = character(),
          tableName = character(),
          isTemporary = logical()
        ))
      }
      temporary <- isTRUE(case$reported$temporary)
      return(data.frame(
        database = if (temporary) "" else case$namespace$schema,
        tableName = case$reported$table,
        isTemporary = temporary
      ))
    }
    if (is.null(case$reported)) {
      return(data.frame(
        name = character(),
        kind = character(),
        database_name = character(),
        schema_name = character(),
        comment = character()
      ))
    }
    data.frame(
      name = case$reported$table,
      kind = "TABLE",
      database_name = case$reported$catalog,
      schema_name = case$reported$schema,
      comment = NA_character_
    )
  }
}

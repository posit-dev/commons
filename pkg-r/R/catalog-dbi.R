# The relations in a generic DBI connection's current schema, named by bare
# table name, or NULL when the backend can't report a current schema or has no
# information_schema (SQLite, for one), where the caller falls back to
# DBI::dbListTables().
dbi_current_relations <- function(con) {
  namespace <- dbi_current_namespace(con)
  if (is.null(namespace)) {
    return(NULL)
  }
  sql <- paste(
    "SELECT table_name, table_type FROM information_schema.tables",
    "WHERE table_schema =",
    DBI::dbQuoteString(con, namespace$schema)
  )
  # DuckDB's information_schema spans every attached database.
  if (!is.null(namespace$catalog)) {
    sql <- paste(
      sql,
      "AND table_catalog =",
      DBI::dbQuoteString(con, namespace$catalog)
    )
  }
  rows <- tryCatch(DBI::dbGetQuery(con, sql), error = function(err) NULL)
  if (is.null(rows)) {
    return(NULL)
  }
  names(rows) <- tolower(names(rows))
  relations <- lapply(seq_len(nrow(rows)), function(i) {
    list(
      id = DBI::Id(schema = namespace$schema, table = rows$table_name[[i]]),
      kind = dbi_relation_kind(rows$table_type[[i]])
    )
  })
  names(relations) <- rows$table_name
  relations
}

dbi_current_namespace <- function(con) {
  for (sql in dbi_namespace_queries) {
    row <- tryCatch(DBI::dbGetQuery(con, sql), error = function(err) NULL)
    if (is.null(row) || nrow(row) != 1L) {
      next
    }
    names(row) <- tolower(names(row))
    schema <- catalog_session_value(row$schema[[1]])
    if (!is.null(schema)) {
      return(list(catalog = catalog_session_value(row$catalog[[1]]), schema = schema))
    }
  }
  NULL
}

# Tried in order; a dialect that lacks a function errors and moves on.
dbi_namespace_queries <- c(
  # PostgreSQL, DuckDB, Redshift
  "SELECT current_database() AS catalog, current_schema() AS schema",
  # SQL Server
  "SELECT DB_NAME() AS catalog, SCHEMA_NAME() AS schema",
  # MySQL and MariaDB, where a schema is a database and table_catalog is 'def'
  "SELECT NULL AS catalog, DATABASE() AS schema"
)

dbi_relation_kind <- function(type) {
  if (grepl("VIEW", toupper(type), fixed = TRUE)) "view" else "table"
}

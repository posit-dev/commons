#' Create a data source
#'
#' A data source is the set of tables available to a [commons()] agent.
#'
#' `data_source()` accepts data that already lives in a database or data frames
#' that don't:
#'
#' * Pass a DBI connection to query it as-is. Nothing is copied; the agent
#'   queries the database directly.
#' * Pass named data frames to load them into an in-process DuckDB database. Use
#'   this when the data isn't already in a database.
#'
#' `data_source_pins()` reads Posit Connect pins into the DuckDB path.
#'
#' The resulting object gives the agent a DBI connection plus a table registry.
#' Use [list_tables()] to list the registered tables.
#'
#' @param ... Either a single DBI connection, or named data frames to register
#'   as tables. When passing data frames, each name becomes a table name the
#'   agent can query.
#' @param tables Tables to expose, used only when a connection is supplied. Can
#'   be a character vector of table names, schema-qualified strings like
#'   `"schema.table"`, or `DBI::Id` objects. Defaults to every table returned by
#'   [DBI::dbListTables()]. Strings containing dots are interpreted as
#'   schema-qualified names; use `DBI::Id(table = "a.b")` for literal table
#'   names containing dots.
#'
#' @section Trust:
#' The `run_sql` tool runs only read-only `SELECT` queries; statements that
#' would modify data or schema (`INSERT`, `UPDATE`, `DROP`, and similar) are
#' rejected before reaching the database. For the in-process DuckDB built from
#' data frames, commons additionally disables extension loading and filesystem
#' access. These are safeguards, not a sandbox: when you supply your own
#' connection, still open it in read-only mode where the backend supports it.
#'
#' @return A `commons_data_source` object.
#'
#' @examples
#' src <- data_source(
#'   sales = data.frame(id = 1:2, revenue = c(100, 200))
#' )
#' list_tables(src)
#'
#' @export
data_source <- function(..., tables = NULL) {
  dots <- rlang::list2(...)

  if (length(dots) == 1 && inherits(dots[[1]], "DBIConnection")) {
    return(data_source_connection(dots[[1]], tables))
  }

  check_named_frames(dots)
  con <- duckdb_connect()
  for (name in names(dots)) {
    DBI::dbWriteTable(
      con,
      name,
      as.data.frame(dots[[name]]),
      overwrite = TRUE
    )
  }
  duckdb_lock_down(con)

  new_data_source(con, names(dots), owned = TRUE)
}

data_source_connection <- function(con, tables, call = rlang::caller_env()) {
  if (is.null(tables)) {
    return(new_data_source(con, DBI::dbListTables(con), owned = FALSE))
  }

  table_registry <- normalize_table_registry(tables, call = call)
  check_table_ids_exist(con, table_registry, call = call)

  new_data_source(
    con,
    table_registry$labels,
    owned = FALSE,
    table_ids = table_registry$ids
  )
}

#' @rdname data_source
#'
#' @param board A `pins` board, e.g. [pins::board_connect()]. On Posit Connect
#'   the default board authenticates as the deployed content's identity.
#' @param names A named character vector of pins to read. The names become table
#'   names; the values are pin names passed to [pins::pin_read()].
#'
#' @export
data_source_pins <- function(board, names) {
  if (!rlang::is_named(names) || !is.character(names)) {
    cli::cli_abort(
      "{.arg names} must be a named character vector of pin names."
    )
  }

  frames <- lapply(names, function(pin) pins::pin_read(board, pin))
  names(frames) <- names(names)
  rlang::inject(data_source(!!!frames))
}

#' Collect named data sources
#'
#' `data_sources()` names the [data_source()] objects available to a
#' [commons()] agent. A source's name is how measures reach its connection: a
#' measure function can declare an argument with the source's name and no
#' `@param` documentation, and the agent supplies that source's connection when
#' the measure runs. See [semantic_layer()] for details.
#'
#' @param ... Named [data_source()] objects.
#'
#' @return A `commons_data_sources` object.
#'
#' @examples
#' data_sources(
#'   sales_db = data_source(
#'     sales = data.frame(id = 1:2, revenue = c(100, 200))
#'   )
#' )
#'
#' @export
data_sources <- function(...) {
  sources <- rlang::list2(...)

  if (length(sources) == 0) {
    cli::cli_abort("Supply at least one named {.fn data_source}.")
  }
  if (!rlang::is_named(sources)) {
    cli::cli_abort("All arguments to {.fn data_sources} must be named.")
  }

  is_source <- vapply(sources, inherits, logical(1), "commons_data_source")
  if (!all(is_source)) {
    cli::cli_abort(
      "Every argument must be a {.fn data_source}; {.arg {names(sources)[!is_source]}} {?is/are} not."
    )
  }

  duplicated_names <- unique(names(sources)[duplicated(names(sources))])
  if (length(duplicated_names)) {
    cli::cli_abort(
      "Source names must be unique; duplicated name{?s}: {.val {duplicated_names}}."
    )
  }

  structure(sources, class = "commons_data_sources")
}

#' List the tables an agent can query
#'
#' @param data_source A [data_source()].
#'
#' @return A character vector of table names.
#'
#' @export
list_tables <- function(data_source) {
  check_data_source(data_source)
  data_source$tables
}

new_data_source <- function(
  con,
  tables,
  owned,
  table_ids = table_ids_from_labels(tables)
) {
  # Disconnect only the DuckDB connection we created; a user-supplied connection
  # has its own owner and lifetime.
  handle <- NULL
  if (owned) {
    handle <- new.env(parent = emptyenv())
    handle$con <- con
    reg.finalizer(
      handle,
      function(h) DBI::dbDisconnect(h$con, shutdown = TRUE),
      onexit = TRUE
    )
  }

  structure(
    list(con = con, tables = tables, table_ids = table_ids, handle = handle),
    class = "commons_data_source"
  )
}

source_describe <- function(source, table, n_sample = 5) {
  id <- source$table_ids[[table]]
  if (is.null(id)) {
    cli::cli_abort(c(
      "No table named {.val {table}}.",
      i = "Available tables: {.val {source$tables}}."
    ))
  }

  sample <- DBI::dbGetQuery(
    source$con,
    sprintf(
      "SELECT * FROM %s LIMIT %d",
      DBI::dbQuoteIdentifier(source$con, id),
      n_sample
    )
  )
  schema <- data.frame(
    column = names(sample),
    type = vapply(sample, function(x) class(x)[[1]], character(1)),
    row.names = NULL
  )
  list(schema = schema, sample = sample)
}

source_query <- function(source, sql) {
  check_query(sql)
  DBI::dbGetQuery(source$con, sql)
}

# A keyword denylist, not a SQL parser: it anchors on the leading statement
# keyword, so it pairs with duckdb_lock_down() and the read-only-connection
# recommendation rather than standing alone. Ported from posit-dev/querychat.
check_query <- function(sql, call = rlang::caller_env()) {
  normalized <- toupper(trimws(gsub(
    " +",
    " ",
    gsub("[\r\n\t]+", " ", sql)
  )))
  blocked <- c(
    "DELETE",
    "TRUNCATE",
    "CREATE",
    "DROP",
    "ALTER",
    "GRANT",
    "REVOKE",
    "EXEC",
    "EXECUTE",
    "CALL",
    "INSERT",
    "UPDATE",
    "MERGE",
    "REPLACE",
    "UPSERT"
  )
  pattern <- paste0("^(", paste(blocked, collapse = "|"), ")\\b")
  if (grepl(pattern, normalized)) {
    matched <- regmatches(normalized, regexpr(pattern, normalized))
    cli::cli_abort(
      c(
        "The query contains a disallowed operation: {.code {matched}}.",
        i = "Only read-only SELECT queries are allowed."
      ),
      call = call
    )
  }
  invisible(sql)
}

# DuckDB-specific hardening for the connection we own: no extension loading,
# no filesystem or external access, and the configuration locked thereafter.
duckdb_lock_down <- function(con) {
  DBI::dbExecute(
    con,
    "
SET allow_community_extensions = false;
SET allow_unsigned_extensions = false;
SET autoinstall_known_extensions = false;
SET autoload_known_extensions = false;
SET enable_external_access = false;
SET disabled_filesystems = 'LocalFileSystem';
SET lock_configuration = true;
"
  )
  invisible(con)
}

# DuckDB defaults its extension and home directories to the package library,
# which is read-only in deployed environments (e.g. Posit Connect). Point them
# at the session temp directory.
#
# `extension_directory` must be set in `config` (i.e. at startup): any query
# first initializes the extension subsystem against this directory, which fails
# when it defaults to the read-only package library. `home_directory`, however,
# is a process-global option; passing it in `config` re-sets a global option on
# every connection, which DuckDB rejects once any DuckDB instance already exists
# in the process (e.g. the connection a data frame `data_source()` holds). Set it
# instead with a session-scoped `SET`, which is safe across coexisting connections.
duckdb_connect <- function() {
  dir <- file.path(tempdir(), "duckdb")
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  con <- DBI::dbConnect(
    duckdb::duckdb(config = list(extension_directory = dir))
  )
  DBI::dbExecute(
    con,
    paste0("SET home_directory=", DBI::dbQuoteString(con, dir), ";")
  )
  con
}

normalize_table_registry <- function(tables, call = rlang::caller_env()) {
  entries <- table_entries(tables, call = call)
  ids <- lapply(entries, table_entry_id, call = call)
  labels <- vapply(ids, table_id_label, character(1), call = call)

  duplicated_labels <- unique(labels[duplicated(labels)])
  if (length(duplicated_labels)) {
    cli::cli_abort(
      "{.arg tables} must not contain duplicate labels: {.val {duplicated_labels}}.",
      call = call
    )
  }

  names(ids) <- labels
  list(labels = labels, ids = ids)
}

table_entries <- function(tables, call = rlang::caller_env()) {
  if (inherits(tables, "Id")) {
    return(list(tables))
  }
  if (is.character(tables)) {
    return(as.list(tables))
  }
  if (is.list(tables)) {
    return(tables)
  }

  cli::cli_abort(
    "{.arg tables} must be a character vector, a list, or a {.cls DBI::Id}.",
    call = call
  )
}

table_entry_id <- function(table, call = rlang::caller_env()) {
  if (inherits(table, "Id")) {
    return(table)
  }

  if (
    !is.character(table) ||
      length(table) != 1 ||
      is.na(table) ||
      table == ""
  ) {
    cli::cli_abort(
      "Each entry in {.arg tables} must be a table name or a {.cls DBI::Id}.",
      call = call
    )
  }

  parts <- strsplit(table, ".", fixed = TRUE)[[1]]
  if (any(parts == "")) {
    cli::cli_abort(
      "Schema-qualified entries in {.arg tables} must not contain empty name components.",
      call = call
    )
  }

  if (length(parts) == 1) {
    return(DBI::Id(table = table))
  }

  DBI::Id(
    schema = paste(parts[-length(parts)], collapse = "."),
    table = parts[[length(parts)]]
  )
}

table_id_label <- function(id, call = rlang::caller_env()) {
  components <- id@name
  table <- components[["table"]]

  if (is.null(table) || is.na(table)) {
    cli::cli_abort(
      "{.cls DBI::Id} entries in {.arg tables} must include a {.arg table} component.",
      call = call
    )
  }

  if (any(is.na(components) | components == "")) {
    cli::cli_abort(
      "{.cls DBI::Id} entries in {.arg tables} must not contain empty name components.",
      call = call
    )
  }

  paste(components, collapse = ".")
}

table_ids_from_labels <- function(tables) {
  ids <- lapply(tables, function(table) DBI::Id(table = table))
  names(ids) <- tables
  ids
}

check_table_ids_exist <- function(con, table_registry, call = rlang::caller_env()) {
  exists <- vapply(
    table_registry$ids,
    function(id) isTRUE(DBI::dbExistsTable(con, id)),
    logical(1)
  )

  if (all(exists)) {
    return(invisible(table_registry))
  }

  missing <- table_registry$labels[!exists]
  cli::cli_abort(
    "{.arg tables} names table{?s} not on the connection: {.val {missing}}.",
    call = call
  )
}

check_named_frames <- function(frames, call = rlang::caller_env()) {
  if (length(frames) == 0) {
    cli::cli_abort("Supply at least one named data frame.", call = call)
  }
  if (!rlang::is_named(frames)) {
    cli::cli_abort(
      "All arguments to {.fn data_source} must be named.",
      call = call
    )
  }
  is_df <- vapply(frames, is.data.frame, logical(1))
  if (!all(is_df)) {
    cli::cli_abort(
      "Every argument must be a data frame; {.arg {names(frames)[!is_df]}} {?is/are} not.",
      call = call
    )
  }
}

check_data_source <- function(data_source, call = rlang::caller_env()) {
  if (!inherits(data_source, "commons_data_source")) {
    cli::cli_abort(
      "{.arg data_source} must be a {.fn data_source}.",
      call = call
    )
  }
}

# A bare data_source() is accepted for the quick-start path; it has no name,
# so measures can't receive its connection by injection.
as_data_sources <- function(x, call = rlang::caller_env()) {
  if (inherits(x, "commons_data_sources")) {
    return(x)
  }
  if (inherits(x, "commons_data_source")) {
    return(structure(list(x), class = "commons_data_sources"))
  }

  cli::cli_abort(
    "{.arg data_sources} must be a {.fn data_source} or {.fn data_sources}.",
    call = call
  )
}

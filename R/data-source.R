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
#' @param tables A character vector of table names to expose, used only when a
#'   connection is supplied. Defaults to every table on the connection.
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
  con <- DBI::dbConnect(duckdb::duckdb())
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
  available <- DBI::dbListTables(con)
  if (is.null(tables)) {
    tables <- available
  } else {
    missing <- setdiff(tables, available)
    if (length(missing)) {
      cli::cli_abort(
        c(
          "{.arg tables} names table{?s} not on the connection: {.val {missing}}.",
          i = "Available tables: {.val {available}}."
        ),
        call = call
      )
    }
  }

  new_data_source(con, tables, owned = FALSE)
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

#' List the tables an agent can query
#'
#' @param source A [data_source()].
#'
#' @return A character vector of table names.
#'
#' @export
list_tables <- function(source) {
  check_data_source(source)
  source$tables
}

new_data_source <- function(con, tables, owned) {
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
    list(con = con, tables = tables, handle = handle),
    class = "commons_data_source"
  )
}

source_describe <- function(source, table, n_sample = 5) {
  if (!table %in% source$tables) {
    cli::cli_abort(c(
      "No table named {.val {table}}.",
      i = "Available tables: {.val {source$tables}}."
    ))
  }

  sample <- DBI::dbGetQuery(
    source$con,
    sprintf(
      "SELECT * FROM %s LIMIT %d",
      DBI::dbQuoteIdentifier(source$con, table),
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

check_data_source <- function(source, call = rlang::caller_env()) {
  if (!inherits(source, "commons_data_source")) {
    cli::cli_abort("{.arg source} must be a {.fn data_source}.", call = call)
  }
}

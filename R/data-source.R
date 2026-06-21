#' Create a data source
#'
#' A data source is the set of tables available to a [commons()] agent.
#' `data_source()` copies named data frames into an in-process DuckDB database.
#' `data_source_pins()` reads Posit Connect pins and creates the same kind of
#' source.
#'
#' The resulting object gives the agent a DBI connection plus a table registry.
#' Use [list_tables()] to list the registered tables.
#'
#' @param ... Named data frames to register as tables. Each name becomes a table
#'   name the agent can query.
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
data_source <- function(...) {
  frames <- rlang::list2(...)
  check_named_frames(frames)

  con <- DBI::dbConnect(duckdb::duckdb())
  for (name in names(frames)) {
    DBI::dbWriteTable(
      con,
      name,
      as.data.frame(frames[[name]]),
      overwrite = TRUE
    )
  }

  new_data_source(con, names(frames))
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

new_data_source <- function(con, tables) {
  # The DuckDB connection has no other owner.
  handle <- new.env(parent = emptyenv())
  handle$con <- con
  reg.finalizer(
    handle,
    function(h) DBI::dbDisconnect(h$con, shutdown = TRUE),
    onexit = TRUE
  )

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
  DBI::dbGetQuery(source$con, sql)
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

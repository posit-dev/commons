local_warehouse_connection <- function(backend, env = parent.frame()) {
  backend <- match.arg(backend, c("snowflake", "databricks"))
  warehouse_test_table(backend)
  skip_if_not_installed("odbc")

  con <- switch(
    backend,
    snowflake = DBI::dbConnect(odbc::snowflake()),
    databricks = DBI::dbConnect(
      odbc::odbc(),
      "Databricks"
    )
  )
  withr::defer(DBI::dbDisconnect(con), envir = env)
  con
}

warehouse_test_table <- function(backend, call = rlang::caller_env()) {
  backend <- match.arg(backend, c("snowflake", "databricks"))
  option <- paste0("commons.test.", backend)
  table <- getOption(option)
  skip_if(
    is.null(table),
    paste0(
      "Set options(", option, " = DBI::Id(...)) to run live warehouse tests"
    )
  )
  if (!inherits(table, "Id")) {
    cli::cli_abort(
      "The {.option {option}} option must be a {.cls DBI::Id} object.",
      call = call
    )
  }
  table
}

warehouse_read_one <- function(con, id) {
  sql <- paste(
    "SELECT * FROM",
    DBI::dbQuoteIdentifier(con, id),
    "LIMIT 1"
  )
  DBI::dbGetQuery(con, sql)
}

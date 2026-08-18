local_warehouse_connection <- function(
  backend,
  require_table = TRUE,
  env = parent.frame()
) {
  backend <- match.arg(backend, c("snowflake", "databricks"))
  if (require_table) {
    warehouse_test_table(backend)
  }
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

warehouse_test_semantic_view <- function(call = rlang::caller_env()) {
  option <- "commons.test.snowflake.semantic_view"
  view <- getOption(option)
  skip_if(
    is.null(view),
    paste0("Set options(", option, " = DBI::Id(...)) to run this test")
  )
  if (!inherits(view, "Id")) {
    cli::cli_abort(
      "The {.option {option}} option must be a {.cls DBI::Id} object.",
      call = call
    )
  }
  view
}

warehouse_read_one <- function(con, id) {
  sql <- paste(
    "SELECT * FROM",
    DBI::dbQuoteIdentifier(con, id),
    "LIMIT 1"
  )
  DBI::dbGetQuery(con, sql)
}

warehouse_test_dictionary <- function(table, column) {
  new_data_dictionary(list(tables = stats::setNames(
    list(list(
      description = "Authored live table description.",
      columns = stats::setNames(
        list(list(
          type = "authored_type",
          description = "Authored live column description."
        )),
        column
      )
    )),
    table
  )))
}

warehouse_definition_spec <- function(table) {
  expressions <- c(
    round_half = "ROUND(2.5) = 3",
    floored_modulus = "MOD(-5, 3) = 1",
    negative_modulus = "MOD(7, -3) = -2",
    modulus_by_zero = "IS_NAN(MOD(1, 0))",
    division_by_zero = "IS_INFINITE(1 / 0)",
    like_pattern = "'Alpha' LIKE 'A_%'",
    similar_pattern = "'Alpha' SIMILAR TO 'A.*'",
    temporal_shift = "NOW() + interval(1, days) > NOW()",
    boolean_fold = "ANY(TRUE) AND ALL(TRUE)",
    null_boolean_fold = "ANY(CASE WHEN TRUE THEN NULL ELSE TRUE END)"
  )
  list(
    tables = list(list(
      name = table,
      definitions = lapply(names(expressions), function(name) {
        list(name = name, expr = expressions[[name]])
      })
    ))
  )
}

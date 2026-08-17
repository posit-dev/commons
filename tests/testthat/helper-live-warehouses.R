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

expect_warehouse_definitions_execute <- function(source) {
  compiled <- definition_compile_source(
    warehouse_definition_spec(source$tables[[1]]),
    source
  )
  definitions <- compiled$tables[[1]]$definitions
  values <- lapply(definitions, function(definition) {
    DBI::dbGetQuery(
      source$con,
      paste("SELECT", definition$sql, "AS value")
    )[[1]][[1]]
  })
  names(values) <- vapply(definitions, `[[`, character(1), "name")
  boolean_fold <- definitions[[match(
    "boolean_fold",
    names(values)
  )]]$sql
  empty_boolean_fold <- DBI::dbGetQuery(
    source$con,
    paste(
      "SELECT",
      boolean_fold,
      "AS value FROM (SELECT 1 AS one) AS empty_rows WHERE FALSE"
    )
  )[[1]][[1]]

  expect_true(all(vapply(
    values[setdiff(
      names(values),
      "null_boolean_fold"
    )],
    function(value) isTRUE(as.logical(value)),
    logical(1)
  )))
  expect_true(is.na(values$null_boolean_fold))
  expect_true(is.na(empty_boolean_fold))
}

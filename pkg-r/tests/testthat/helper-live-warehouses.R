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

warehouse_test_denied_table <- function(backend, call = rlang::caller_env()) {
  backend <- match.arg(backend, c("snowflake", "databricks"))
  option <- paste0("commons.test.", backend, ".denied_table")
  table <- getOption(option)
  skip_if(is.null(table), paste0("Set options(", option, " = DBI::Id(...))"))
  if (!inherits(table, "Id")) {
    cli::cli_abort(
      "The {.option {option}} option must be a {.cls DBI::Id} object.",
      call = call
    )
  }
  table
}

warehouse_test_alternate_role <- function(call = rlang::caller_env()) {
  option <- "commons.test.snowflake.alternate_role"
  role <- getOption(option)
  skip_if(is.null(role), paste0("Set options(", option, " = \"ROLE\")"))
  rlang::check_string(role, call = call)
  role
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

warehouse_test_parameterized_model <- function(
  backend,
  call = rlang::caller_env()
) {
  backend <- match.arg(backend, c("snowflake", "databricks"))
  option <- paste0("commons.test.", backend, ".parameterized_model")
  model <- getOption(option)
  skip_if(is.null(model), paste0("Set options(", option, " = DBI::Id(...))"))
  if (!inherits(model, "Id")) {
    cli::cli_abort(
      "The {.option {option}} option must be a {.cls DBI::Id} object.",
      call = call
    )
  }
  arguments_option <- paste0(option, "_arguments")
  arguments <- getOption(arguments_option)
  skip_if(
    is.null(arguments),
    paste0("Set options(", arguments_option, " = list(...))")
  )
  if (!is.list(arguments) || is.null(names(arguments))) {
    cli::cli_abort(
      "The {.option {arguments_option}} option must be a named list.",
      call = call
    )
  }
  list(id = model, arguments = arguments)
}

warehouse_test_verified_query_view <- function(call = rlang::caller_env()) {
  option <- "commons.test.snowflake.verified_query_view"
  view <- getOption(option)
  skip_if(is.null(view), paste0("Set options(", option, " = DBI::Id(...))"))
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

warehouse_test_calculation <- function(source, table) {
  column <- source_describe(source, table_id_label(table))$schema$column[[1]]
  new_trusted_calculation(
    "bound_preview",
    "Preview an allowed warehouse column with a bound value.",
    paste(
      "SELECT {{column}}, {{value}} AS bound_value FROM",
      DBI::dbQuoteIdentifier(data_source_state(source)$con, table),
      "LIMIT 1"
    ),
    arguments = list(
      new_typed_argument(
        "column",
        "string",
        identifier = TRUE,
        choices = column
      ),
      new_typed_argument("value", "number")
    )
  )
}

expect_warehouse_trusted_calculation <- function(backend) {
  table <- warehouse_test_table(backend)
  con <- local_warehouse_connection(backend)
  source <- data_source(con, tables = table)
  state <- data_source_state(source)
  state$calculations <- list(warehouse_test_calculation(source, table))
  sources <- stats::setNames(list(source), backend)
  registry <- calculations_registry(sources)
  calculation <- state$calculations[[1]]
  column <- names(calculation$arguments$column$choices)[[1]]

  result <- call_calculation_impl(
    registry,
    sources,
    new_handle_store(),
    "bound_preview",
    jsonlite::toJSON(list(column = column, value = 2), auto_unbox = TRUE)
  )

  expect_equal(result@extra$commons_tag, "A")
  expect_error(
    call_calculation_impl(
      registry,
      sources,
      new_handle_store(),
      "bound_preview",
      '{"column":"not_allowed","value":2}'
    ),
    "does not allow"
  )
  expect_error(
    call_calculation_impl(
      registry,
      sources,
      new_handle_store(),
      "bound_preview",
      jsonlite::toJSON(
        list(column = column, value = "two"),
        auto_unbox = TRUE
      )
    ),
    "must be a number"
  )
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

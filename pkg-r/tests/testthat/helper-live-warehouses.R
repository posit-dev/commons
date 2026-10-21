# The variable names come from tests/shared/live-warehouse-env.json, which the
# Python suite reads as well. The test table is one of the tables
# scripts/provision-live-warehouse.py creates in the configured schema.
live_warehouse_table <- "orders"

live_warehouse_spec <- function(backend) {
  backend <- match.arg(backend, c("snowflake", "databricks"))
  shared_fixture("live-warehouse-env")$backends[[backend]]
}

# Skips unless the backend's connection variables and schema are all set.
require_live_warehouse <- function(backend) {
  spec <- live_warehouse_spec(backend)
  names <- c(
    unlist(spec$connection$required),
    spec$fixtures$schema$variable
  )
  missing <- names[!nzchar(Sys.getenv(names))]
  skip_if(
    length(missing) > 0L,
    paste0("live ", backend, " needs ", paste(sort(missing), collapse = ", "))
  )
  invisible(spec)
}

live_warehouse_value <- function(backend, fixture) {
  variable <- live_warehouse_spec(backend)$fixtures[[fixture]]$variable
  value <- Sys.getenv(variable)
  skip_if(!nzchar(value), paste("Set", variable, "to run this test"))
  value
}

live_warehouse_id <- function(backend, fixture, call = rlang::caller_env()) {
  spec <- live_warehouse_spec(backend)$fixtures[[fixture]]
  value <- live_warehouse_value(backend, fixture)
  parts <- strsplit(value, ".", fixed = TRUE)[[1]]
  if (length(parts) != spec$arity) {
    cli::cli_abort(
      "{.envvar {spec$variable}} must name {spec$arity} dotted identifier parts, not {.val {value}}.",
      call = call
    )
  }
  names(parts) <- c("catalog", "schema", "table")[seq_along(parts)]
  do.call(DBI::Id, as.list(parts))
}

local_warehouse_connection <- function(
  backend,
  require_table = TRUE,
  env = parent.frame()
) {
  backend <- match.arg(backend, c("snowflake", "databricks"))
  require_live_warehouse(backend)
  if (require_table) {
    warehouse_test_table(backend)
  }
  skip_if_not_installed("odbc")

  con <- switch(
    backend,
    snowflake = DBI::dbConnect(
      odbc::snowflake(),
      account = Sys.getenv("SNOWFLAKE_ACCOUNT"),
      uid = Sys.getenv("SNOWFLAKE_USER"),
      authenticator = "SNOWFLAKE_JWT",
      priv_key_file = Sys.getenv("SNOWFLAKE_PRIVATE_KEY_FILE"),
      warehouse = Sys.getenv("SNOWFLAKE_WAREHOUSE")
    ),
    # odbc::databricks() resolves credentials from the environment: a token,
    # a client secret, or a federated OIDC token.
    databricks = DBI::dbConnect(
      odbc::databricks(),
      workspace = Sys.getenv("DATABRICKS_HOST"),
      httpPath = Sys.getenv("DATABRICKS_HTTP_PATH")
    )
  )
  withr::defer(DBI::dbDisconnect(con), envir = env)
  con
}

warehouse_test_table <- function(backend) {
  require_live_warehouse(backend)
  schema <- live_warehouse_id(backend, "schema")
  do.call(DBI::Id, c(as.list(schema@name), table = live_warehouse_table))
}

warehouse_test_denied_table <- function(backend) {
  live_warehouse_id(backend, "denied_table")
}

warehouse_test_alternate_role <- function() {
  live_warehouse_value("snowflake", "alternate_role")
}

warehouse_test_semantic_view <- function() {
  live_warehouse_id("snowflake", "semantic_view")
}

warehouse_test_verified_query_view <- function() {
  live_warehouse_id("snowflake", "verified_query_view")
}

warehouse_test_parameterized_model <- function(
  backend,
  call = rlang::caller_env()
) {
  model <- live_warehouse_id(backend, "parameterized_model")
  variable <- live_warehouse_spec(backend)$fixtures$parameterized_model_arguments$variable
  arguments <- jsonlite::fromJSON(
    live_warehouse_value(backend, "parameterized_model_arguments"),
    simplifyVector = FALSE
  )
  if (!is.list(arguments) || is.null(names(arguments))) {
    cli::cli_abort(
      "{.envvar {variable}} must be a JSON object.",
      call = call
    )
  }
  list(id = model, arguments = arguments)
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
  calculation <- state$calculations[[1]]
  column <- names(calculation$arguments$column$choices)[[1]]

  result <- call_calculation_impl(
    sources,
    new_handle_store(),
    "bound_preview",
    jsonlite::toJSON(list(column = column, value = 2), auto_unbox = TRUE)
  )

  expect_equal(result@extra$commons_tag, "A")
  expect_error(
    call_calculation_impl(
      sources,
      new_handle_store(),
      "bound_preview",
      '{"column":"not_allowed","value":2}'
    ),
    "does not allow"
  )
  expect_error(
    call_calculation_impl(
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

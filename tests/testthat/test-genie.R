test_that("Genie Agent configuration retains no credentials", {
  config <- genie_agent(
    "0123456789abcdef0123456789abcdef",
    workspace = "https://example.cloud.databricks.com/",
    profile = "example"
  )

  expect_equal(config$workspace, "https://example.cloud.databricks.com")
  expect_equal(config$profile, "example")
  expect_null(config$token)
  expect_snapshot(genie_agent("not-an-id"), error = TRUE)
})

test_that("Genie token callbacks are forgotten after import", {
  token <- function() "short-lived-token"
  config <- genie_agent(
    "0123456789abcdef0123456789abcdef",
    workspace = "https://example.cloud.databricks.com",
    token = token
  )
  options <- data_source_options(genie = config)

  expect_identical(options$genie$token, token)
  expect_null(catalog_forget_credentials(options)$genie$token)
})

test_that("serialized Genie context is scoped and routed by authority", {
  fixture <- paste(
    readLines(test_path("fixtures", "genie-v2.json"), warn = FALSE),
    collapse = "\n"
  )
  provider <- genie_test_provider()
  fetch <- function(config) list(
    response = list(
      serialized_space = fixture,
      title = "Taxi Agent",
      warehouse_id = "warehouse-id",
      creator_user_name = "owner@example.com"
    ),
    principal = "retriever@example.com"
  )

  genie_import(
    provider,
    genie_agent("0123456789abcdef0123456789abcdef"),
    fetch = fetch
  )

  catalog <- provider$catalog
  relation <- catalog$relations[["relation:trips"]]
  model <- catalog$models[[1]]
  deliveries <- vapply(catalog$context, `[[`, character(1), "delivery")
  calculation_names <- vapply(catalog$calculations, `[[`, character(1), "name")

  expect_equal(relation$description, "One row is one taxi trip.")
  expect_equal(relation$columns$pickup_zip$description, "Pickup postal code.")
  expect_equal(relation$columns$rider_email$display, "restricted")
  expect_equal(model$datasets, "relation:trips")
  expect_true("trips_by_zip" %in% calculation_names)
  expect_true("normalize_zip" %in% calculation_names)
  expect_false("static-example" %in% calculation_names)
  expect_true("evaluation" %in% deliveries)
  expect_true(all(c("first_touch", "retrieval") %in% deliveries))
  expect_true(model$extensions$genie$future_top_level_field$keep)
  expect_true(any(vapply(
    catalog$diagnostics,
    function(x) x$code == "genie_asset_out_of_scope",
    logical(1)
  )))
  expect_true(any(vapply(
    catalog$diagnostics,
    function(x) x$code == "genie_identity_mismatch",
    logical(1)
  )))
})

test_that("Genie parameters are typed, defaulted, and bound", {
  fixture <- paste(
    readLines(test_path("fixtures", "genie-v2.json"), warn = FALSE),
    collapse = "\n"
  )
  provider <- genie_test_provider()
  fetch <- function(config) list(
    response = list(serialized_space = fixture),
    principal = "executor@example.com"
  )
  genie_import(
    provider,
    genie_agent("0123456789abcdef0123456789abcdef"),
    fetch = fetch
  )
  calculation <- Filter(
    function(x) x$name == "trips_by_zip",
    provider$catalog$calculations
  )[[1]]

  values <- validate_catalog_calculation_args(calculation, list())
  prepared <- prepare_catalog_calculation(
    calculation$execution,
    calculation$arguments,
    values,
    provider$con
  )

  expect_equal(values$zip, "10001")
  expect_equal(prepared$params, list("10001"))
  expect_match(prepared$sql, "pickup_zip = ?", fixed = TRUE)
  expect_false(grepl("10001", prepared$sql, fixed = TRUE))
})

test_that("Genie parsing is bounded and versions fail closed", {
  expect_snapshot(
    genie_parse_serialized('{"version": 99}'),
    error = TRUE
  )
  parsed <- genie_parse_serialized('{"version": 2, "text": "ok"}')
  expect_equal(parsed[c("version", "text")], list(version = 2L, text = "ok"))
  expect_snapshot(
    genie_parse_serialized(paste0(
      '{"version": 2, "text": "',
      paste(rep("x", 250001), collapse = ""),
      '"}'
    )),
    error = TRUE
  )
})

test_that("Genie changes are fetched for each provider construction", {
  provider <- genie_test_provider()
  calls <- 0L
  fetch <- function(config) {
    calls <<- calls + 1L
    list(
      response = list(serialized_space = sprintf(
        '{"version":2,"data_sources":{"tables":[{"identifier":"samples.nyctaxi.trips"}]},"instructions":{"text_instructions":[{"content":["revision %s"]}]}}',
        calls
      )),
      principal = "executor@example.com"
    )
  }
  config <- genie_agent("0123456789abcdef0123456789abcdef")

  genie_import(provider, config, fetch)
  first <- provider$catalog$models[[1]]$fingerprint
  provider <- genie_test_provider()
  genie_import(provider, config, fetch)
  second <- provider$catalog$models[[1]]$fingerprint

  expect_equal(calls, 2L)
  expect_false(identical(first, second))
})

test_that("Genie permission failures are independent of DBI metadata", {
  provider <- genie_test_provider()
  fetch <- function(config) {
    cli::cli_abort("The REST identity cannot edit this Agent.")
  }

  expect_snapshot(
    genie_import(
      provider,
      genie_agent("0123456789abcdef0123456789abcdef"),
      fetch
    ),
    error = TRUE
  )
  expect_length(provider$catalog$relations, 1)
})

test_that("Genie context requires DBI query access", {
  fixture <- paste(
    readLines(test_path("fixtures", "genie-v2.json"), warn = FALSE),
    collapse = "\n"
  )
  provider <- genie_test_provider()
  provider$catalog$relations[["relation:trips"]]$access <- new_catalog_access()
  local_mocked_bindings(
    catalog_relation_queryability = function(con, path) {
      simpleError("not authorized")
    }
  )
  fetch <- function(config) list(
    response = list(serialized_space = fixture),
    principal = "executor@example.com"
  )

  genie_import(
    provider,
    genie_agent("0123456789abcdef0123456789abcdef"),
    fetch
  )
  codes <- vapply(provider$catalog$diagnostics, `[[`, character(1), "code")

  expect_length(provider$catalog$models, 0)
  expect_length(provider$catalog$context, 0)
  expect_true("genie_asset_unqueryable" %in% codes)
})

test_that("live Genie import honors the selected relation", {
  skip_if_not(identical(Sys.getenv("COMMONS_LIVE_DATABRICKS"), "true"))
  required <- c(
    "COMMONS_DATABRICKS_GENIE_ID",
    "COMMONS_DATABRICKS_GENIE_PROFILE",
    "COMMONS_DATABRICKS_CATALOG",
    "COMMONS_DATABRICKS_SCHEMA",
    "COMMONS_DATABRICKS_TABLE"
  )
  skip_if(any(!nzchar(Sys.getenv(required))))
  con <- DBI::dbConnect(odbc::odbc(), "Databricks")
  withr::defer(DBI::dbDisconnect(con))
  source <- data_source(
    con,
    options = data_source_options(
      include = DBI::Id(
        catalog = Sys.getenv("COMMONS_DATABRICKS_CATALOG"),
        schema = Sys.getenv("COMMONS_DATABRICKS_SCHEMA"),
        table = Sys.getenv("COMMONS_DATABRICKS_TABLE")
      ),
      genie = genie_agent(
        Sys.getenv("COMMONS_DATABRICKS_GENIE_ID"),
        profile = Sys.getenv("COMMONS_DATABRICKS_GENIE_PROFILE")
      )
    )
  )

  expect_true(length(source$provider$catalog$context) > 0)
  expect_true(length(source$provider$catalog$sources[[1]]$extensions$genie) > 0)
})

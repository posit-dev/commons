test_that("data_source_options normalizes exact selectors", {
  options <- data_source_options(include = c("sales", "crm.sales"))

  expect_s3_class(options, "commons_data_source_options")
  expect_identical(
    lapply(options$include, function(id) id@name),
    list(c(table = "sales"), c(table = "crm.sales"))
  )
  qualified <- DBI::Id(catalog = "analytics", schema = "crm", table = "sales")
  expect_identical(data_source_options(qualified)$include[[1]], qualified)
})

test_that("data_source_options validates its values", {
  expect_error(data_source_options(include = ""), "non-empty table names")
  expect_error(
    data_source_options(include = NA_character_),
    "non-empty table names"
  )
  expect_error(
    data_source_options(include = character()),
    "at least one object"
  )
  expect_error(data_source_options(include = 1), "must be a character vector")
  expect_error(
    data_source_options(include = list("sales")),
    "Every entry.*DBI::Id"
  )
  expect_error(
    data_source_options(include = DBI::Id(schema = "")),
    "non-empty components"
  )
})

test_that("options character selectors are literal table names", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, 'CREATE TABLE "crm.sales" (order_id VARCHAR)')
  DBI::dbExecute(con, 'INSERT INTO "crm.sales" VALUES (\'o01\')')

  src <- data_source(
    con,
    options = data_source_options(include = "crm.sales")
  )

  expect_equal(list_tables(src), "crm.sales")
  expect_identical(src$table_ids[["crm.sales"]]@name, c(table = "crm.sales"))
  expect_equal(
    source_describe(src, "crm.sales", n_sample = 1)$sample$order_id,
    "o01"
  )
})

test_that("options preserve and quote structured identifiers", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, 'CREATE SCHEMA "crm raw"')
  id <- DBI::Id(schema = "crm raw", table = "sales.daily")
  quoted <- DBI::dbQuoteIdentifier(con, id)
  DBI::dbExecute(con, paste("CREATE TABLE", quoted, "(order_id VARCHAR)"))
  DBI::dbExecute(con, paste("INSERT INTO", quoted, "VALUES ('o01')"))

  src <- data_source(con, options = data_source_options(include = id))

  expect_equal(list_tables(src), "crm raw.sales.daily")
  expect_identical(src$table_ids[["crm raw.sales.daily"]], id)
  expect_equal(
    source_describe(src, "crm raw.sales.daily", n_sample = 1)$sample$order_id,
    "o01"
  )
})

test_that("data_source options are confined to DBI connections", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "sales", data.frame(id = 1L))
  options <- data_source_options(include = "sales")

  expect_error(
    data_source(con, tables = "sales", options = options),
    "only one of `tables` and `options`"
  )
  expect_error(
    data_source(con, options = list(include = "sales")),
    "must come from"
  )
  expect_error(
    data_source(sales = data.frame(id = 1L), options = options),
    "only be used with a DBI connection"
  )
})

test_that("namespace options stop at the backend expansion boundary", {
  options <- data_source_options(include = DBI::Id(schema = "crm"))
  expect_identical(options$include[[1]], DBI::Id(schema = "crm"))

  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_error(
    data_source(con, options = options),
    "Namespace selections in `options` are not yet supported"
  )
})

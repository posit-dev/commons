test_that("data_source registers frames as queryable tables", {
  src <- test_source()
  expect_equal(list_tables(src), "sales")

  res <- source_query(src, "SELECT count(*) AS n FROM sales")
  expect_equal(res$n, 6)
})

test_that("source_describe returns schema and samples", {
  src <- test_source()
  d <- source_describe(src, "sales", n_sample = 2)

  expect_setequal(
    d$schema$column,
    c("order_id", "revenue", "region", "product_line", "rep")
  )
  expect_equal(nrow(d$sample), 2)
})

test_that("source_describe errors informatively for unknown tables", {
  expect_snapshot(source_describe(test_source(), "nope"), error = TRUE)
})

test_that("data_source wraps an existing connection without copying", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "sales", test_sales())
  DBI::dbWriteTable(con, "reps", data.frame(rep = "Ada"))

  src <- data_source(con)
  expect_identical(src$con, con)
  expect_setequal(list_tables(src), c("sales", "reps"))

  src_one <- data_source(con, tables = "sales")
  expect_equal(list_tables(src_one), "sales")
})

test_that("data_source supports schema-qualified connection tables", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA crm")
  DBI::dbExecute(con, "CREATE TABLE crm.sales (order_id VARCHAR, revenue DOUBLE)")
  DBI::dbExecute(con, "INSERT INTO crm.sales VALUES ('o01', 100)")

  src <- data_source(con, tables = "crm.sales")

  expect_equal(list_tables(src), "crm.sales")
  d <- source_describe(src, "crm.sales")
  expect_equal(d$schema$column, c("order_id", "revenue"))
  expect_equal(d$sample$order_id, "o01")
})

test_that("data_source supports explicit DBI identifiers", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA crm")
  DBI::dbExecute(con, "CREATE TABLE crm.sales (order_id VARCHAR, revenue DOUBLE)")
  DBI::dbExecute(con, "INSERT INTO crm.sales VALUES ('o01', 100)")

  src <- data_source(
    con,
    tables = list(DBI::Id(schema = "crm", table = "sales"))
  )

  expect_equal(list_tables(src), "crm.sales")
  d <- source_describe(src, "crm.sales")
  expect_equal(d$sample$order_id, "o01")
})

test_that("data_source keeps default connection discovery unvalidated", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA crm")
  DBI::dbExecute(con, "CREATE TABLE crm.sales (order_id VARCHAR)")

  src <- data_source(con)

  expect_equal(list_tables(src), "sales")
})

test_that("data_source errors for tables absent from the connection", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "sales", test_sales())

  expect_snapshot(data_source(con, tables = "nope"), error = TRUE)
})

test_that("source_query rejects non-SELECT statements", {
  src <- test_source()
  expect_error(source_query(src, "DROP TABLE sales"), "disallowed operation")
  expect_error(source_query(src, "DELETE FROM sales"), "disallowed operation")
  expect_error(
    source_query(src, "INSERT INTO sales VALUES ('o07', 1, 'EMEA', 'x', 'y')"),
    "disallowed operation"
  )
  expect_equal(source_query(src, "SELECT count(*) AS n FROM sales")$n, 6)
})

test_that("check_query ignores keywords that aren't the leading statement", {
  expect_invisible(check_query("SELECT 'dropped' AS status FROM sales"))
})

test_that("the frame-path DuckDB is locked down", {
  src <- test_source()
  expect_error(
    DBI::dbExecute(src$con, "SET enable_external_access = true")
  )
})

test_that("data_source rejects unnamed or non-data-frame input", {
  expect_snapshot(data_source(data.frame(x = 1)), error = TRUE)
  expect_snapshot(data_source(a = 1), error = TRUE)
})

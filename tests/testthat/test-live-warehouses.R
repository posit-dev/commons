test_that("live Snowflake connection reads a configured table", {
  objects <- warehouse_test_objects("snowflake")
  con <- local_warehouse_connection("snowflake")

  session <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT CURRENT_USER() AS principal,",
      "CURRENT_ROLE() AS role,",
      "CURRENT_DATABASE() AS catalog,",
      "CURRENT_SCHEMA() AS schema"
    )
  )
  source <- data_source(
    con,
    options = data_source_options(include = objects$table, sample_rows = 1L)
  )
  label <- paste(objects$table@name, collapse = ".")
  rows <- source_describe(source, label, n_sample = 1)$sample
  names(session) <- tolower(names(session))

  expect_identical(source$table_ids[[label]], objects$table)
  expect_equal(nrow(session), 1)
  expect_named(session, c("principal", "role", "catalog", "schema"))
  expect_true(nzchar(session$principal[[1]]))
  expect_s3_class(rows, "data.frame")
  expect_true(nrow(rows) <= 1)
})

test_that("live Databricks connection reads a configured table", {
  objects <- warehouse_test_objects("databricks")
  con <- local_warehouse_connection("databricks")

  session <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT CURRENT_USER() AS principal,",
      "CURRENT_CATALOG() AS catalog,",
      "CURRENT_SCHEMA() AS schema"
    )
  )
  source <- data_source(
    con,
    options = data_source_options(include = objects$table, sample_rows = 1L)
  )
  label <- paste(objects$table@name, collapse = ".")
  rows <- source_describe(source, label, n_sample = 1)$sample
  names(session) <- tolower(names(session))

  expect_identical(source$table_ids[[label]], objects$table)
  expect_equal(nrow(session), 1)
  expect_named(session, c("principal", "catalog", "schema"))
  expect_true(nzchar(session$principal[[1]]))
  expect_s3_class(rows, "data.frame")
  expect_true(nrow(rows) <= 1)
})

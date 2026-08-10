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
  rows <- warehouse_read_one(con, objects$table)
  names(session) <- tolower(names(session))

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
  rows <- warehouse_read_one(con, objects$table)
  names(session) <- tolower(names(session))

  expect_equal(nrow(session), 1)
  expect_named(session, c("principal", "catalog", "schema"))
  expect_true(nzchar(session$principal[[1]]))
  expect_s3_class(rows, "data.frame")
  expect_true(nrow(rows) <= 1)
})

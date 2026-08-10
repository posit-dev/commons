test_that("Snowflake SHOW results retain native relation metadata", {
  rows <- data.frame(
    name = c("Sales.Report", "ORDERS", "STAGE"),
    database_name = c("Data.Base", "ANALYTICS", "ANALYTICS"),
    schema_name = c("Odd Schema", "PUBLIC", "PUBLIC"),
    kind = c("VIEW", "TABLE", "STAGE"),
    comment = c("A useful view", "", "Ignored"),
    stringsAsFactors = FALSE
  )

  relations <- snowflake_relations_from_show(rows)

  expect_length(relations, 2)
  expect_equal(relations[[1]]$kind, "view")
  expect_equal(relations[[1]]$description, "A useful view")
  expect_null(relations[[2]]$description)
  expect_identical(
    relations[[1]]$id,
    DBI::Id(
      catalog = "Data.Base",
      schema = "Odd Schema",
      table = "Sales.Report"
    )
  )

  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(
    as.character(DBI::dbQuoteIdentifier(con, relations[[1]]$id)),
    '"Data.Base"."Odd Schema"."Sales.Report"'
  )
})

test_that("Snowflake identifiers distinguish namespaces and relations", {
  expect_equal(snowflake_id_type(DBI::Id(catalog = "DB")), "namespace")
  expect_equal(snowflake_id_type(DBI::Id(schema = "PUBLIC")), "namespace")
  expect_equal(
    snowflake_id_type(DBI::Id(catalog = "DB", schema = "PUBLIC")),
    "namespace"
  )
  expect_equal(snowflake_id_type(DBI::Id(table = "ORDERS")), "relation")
  expect_equal(
    snowflake_id_type(DBI::Id(schema = "PUBLIC", table = "ORDERS")),
    "relation"
  )
  expect_error(
    snowflake_id_type(DBI::Id(catalog = "DB", table = "ORDERS")),
    "without skipped"
  )
  expect_error(
    snowflake_id_type(DBI::Id(schema = "", table = "ORDERS")),
    "without skipped"
  )
})

test_that("Snowflake current namespace requires a database and schema", {
  local_mocked_bindings(
    dbGetQuery = function(...) {
      data.frame(catalog = NA_character_, schema = NA_character_)
    },
    .package = "DBI"
  )

  expect_error(
    snowflake_current_namespace(NULL),
    "no current database and schema"
  )
})

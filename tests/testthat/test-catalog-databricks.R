test_that("Databricks information schema retains native relation metadata", {
  rows <- data.frame(
    table_catalog = c("Data.Catalog", "main"),
    table_schema = c("Odd Schema", "default"),
    table_name = c("Sales.Report", "orders"),
    table_type = c("VIEW", "MANAGED"),
    comment = c("A useful view", ""),
    stringsAsFactors = FALSE
  )

  relations <- databricks_relations_from_information_schema(rows)

  expect_length(relations, 2)
  expect_equal(relations[[1]]$kind, "view")
  expect_equal(relations[[1]]$description, "A useful view")
  expect_equal(relations[[2]]$kind, "table")
  expect_null(relations[[2]]$description)
  expect_identical(
    relations[[1]]$id,
    DBI::Id(
      catalog = "Data.Catalog",
      schema = "Odd Schema",
      table = "Sales.Report"
    )
  )

  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(
    as.character(DBI::dbQuoteIdentifier(con, relations[[1]]$id)),
    '"Data.Catalog"."Odd Schema"."Sales.Report"'
  )
})

test_that("Databricks descriptions retain columns and nullability", {
  rows <- data.frame(
    col_name = c(
      "Order ID",
      "notes",
      "# Partition Information",
      "notes"
    ),
    data_type = c("bigint", "string", "", "string"),
    comment = c("Primary key", NA, "", NA),
    stringsAsFactors = FALSE
  )
  nullable <- c("Order ID" = FALSE, notes = TRUE)

  columns <- databricks_columns_from_describe(rows, nullable)

  expect_equal(columns$column, c("Order ID", "notes"))
  expect_equal(columns$type, c("bigint", "string"))
  expect_identical(columns$nullable, c(FALSE, TRUE))
  expect_equal(columns$description, c("Primary key", NA))
})

test_that("Databricks identifiers distinguish namespaces and relations", {
  expect_equal(databricks_id_type(DBI::Id(catalog = "main")), "namespace")
  expect_equal(databricks_id_type(DBI::Id(schema = "default")), "namespace")
  expect_equal(
    databricks_id_type(DBI::Id(catalog = "main", schema = "default")),
    "namespace"
  )
  expect_equal(databricks_id_type(DBI::Id(table = "orders")), "relation")
  expect_equal(
    databricks_id_type(DBI::Id(schema = "default", table = "orders")),
    "relation"
  )
})

test_that("Databricks identifiers cannot skip components", {
  expect_snapshot(
    databricks_id_type(DBI::Id(catalog = "main", table = "orders")),
    error = TRUE
  )
})

test_that("Databricks current namespace requires a catalog and schema", {
  local_mocked_bindings(
    dbGetQuery = function(...) {
      data.frame(catalog = NA_character_, schema = NA_character_)
    },
    .package = "DBI"
  )

  expect_snapshot(
    databricks_current_namespace(NULL),
    error = TRUE
  )
})

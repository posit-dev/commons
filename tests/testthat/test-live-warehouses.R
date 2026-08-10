test_that("live Snowflake discovers and describes catalog relations", {
  table <- warehouse_test_table("snowflake")
  con <- local_warehouse_connection("snowflake")
  components <- table@name
  skip_if_not(
    all(c("catalog", "schema", "table") %in% names(components)),
    "The Snowflake test table must be fully qualified"
  )

  session <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT CURRENT_USER() AS principal,",
      "CURRENT_ROLE() AS role,",
      "CURRENT_DATABASE() AS catalog,",
      "CURRENT_SCHEMA() AS schema"
    )
  )
  rows <- warehouse_read_one(con, table)
  names(session) <- tolower(names(session))
  label <- table_id_label(table)

  exact <- data_source(con, tables = table)
  described <- source_describe(exact, label)

  namespace <- DBI::Id(
    catalog = components[["catalog"]],
    schema = components[["schema"]]
  )
  schema_source <- data_source(con, tables = namespace)
  catalog_source <- data_source(
    con,
    tables = DBI::Id(catalog = components[["catalog"]])
  )

  DBI::dbExecute(
    con,
    paste(
      "USE DATABASE",
      DBI::dbQuoteIdentifier(
        con,
        DBI::Id(catalog = components[["catalog"]])
      )
    )
  )
  DBI::dbExecute(
    con,
    paste("USE SCHEMA", DBI::dbQuoteIdentifier(con, namespace))
  )
  current_source <- data_source(con)

  expect_equal(nrow(session), 1)
  expect_named(session, c("principal", "role", "catalog", "schema"))
  expect_true(nzchar(session$principal[[1]]))
  expect_s3_class(rows, "data.frame")
  expect_true(nrow(rows) <= 1)
  expect_equal(list_tables(exact), label)
  expect_identical(exact$table_ids[[label]], table)
  expect_named(
    described$schema,
    c("column", "type", "nullable", "description")
  )
  expect_true(nrow(described$sample) <= 5)
  expect_equal(names(described$sample), described$schema$column)
  expect_true(exact$snowflake_relations[[label]]$kind %in% c("table", "view"))
  expect_true(label %in% list_tables(schema_source))
  expect_true(label %in% list_tables(catalog_source))
  expect_true(label %in% list_tables(current_source))
  expect_true(all(vapply(
    schema_source$snowflake_relations,
    function(x) x$kind %in% c("table", "view"),
    logical(1)
  )))

  tool <- describe_table_tool(exact, label)
  expect_match(tool@value, "Relation type")
  expect_match(tool@value, "nullable")
  expect_match(tool@value, "Sample rows")
})

test_that("live Databricks connection reads a configured table", {
  table <- warehouse_test_table("databricks")
  con <- local_warehouse_connection("databricks")

  session <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT CURRENT_USER() AS principal,",
      "CURRENT_CATALOG() AS catalog,",
      "CURRENT_SCHEMA() AS schema"
    )
  )
  rows <- warehouse_read_one(con, table)
  names(session) <- tolower(names(session))

  expect_equal(nrow(session), 1)
  expect_named(session, c("principal", "catalog", "schema"))
  expect_true(nzchar(session$principal[[1]]))
  expect_s3_class(rows, "data.frame")
  expect_true(nrow(rows) <= 1)
})

test_that("catalog calculations enter search_pool and execute as trusted", {
  source <- calculation_test_source()
  registry <- catalog_calculations_registry(list(warehouse = source))

  found <- search_pool_text(
    list(),
    empty_definitions(),
    "count all sales",
    "warehouse",
    registry
  )
  result <- call_catalog_calculation(
    registry,
    "sales_count",
    handles = new_handle_store()
  )

  expect_match(found, "call_calculation")
  expect_match(found, "sales_count")
  expect_match(result@value, "6")
  expect_equal(result@extra$commons_tag, "A")
})

test_that("catalog calculation values are bound and identifiers are allowlisted", {
  source <- calculation_test_source(parameterized = TRUE)
  registry <- catalog_calculations_registry(list(warehouse = source))
  payload <- "EMEA'; DROP TABLE sales; --"

  result <- call_catalog_calculation(
    registry,
    "sales_value",
    jsonlite::toJSON(
      list(region = payload, column = "order_id"),
      auto_unbox = TRUE
    )
  )

  expect_match(result@value, "DROP TABLE sales", fixed = TRUE)
  expect_equal(DBI::dbGetQuery(source$con, "SELECT count(*) AS n FROM sales")$n, 6)
  expect_snapshot(
    call_catalog_calculation(
      registry,
      "sales_value",
      '{"region":"EMEA","column":"order_id; DROP TABLE sales"}'
    ),
    error = TRUE
  )
  expect_snapshot(
    call_catalog_calculation(
      registry,
      "sales_value",
      '{"column":"order_id"}'
    ),
    error = TRUE
  )
})

test_that("catalog calculations do not trust rejected execution", {
  source <- calculation_test_source()
  calculation <- source$catalog$calculations[[1]]
  calculation$execution$sql <- "DELETE FROM sales"
  source$catalog$calculations[[1]] <- calculation
  registry <- catalog_calculations_registry(list(warehouse = source))

  expect_snapshot(
    call_catalog_calculation(registry, "sales_count"),
    error = TRUE
  )
  expect_equal(DBI::dbGetQuery(source$con, "SELECT count(*) AS n FROM sales")$n, 6)
})

test_that("validate_measure_args coerces valid arguments", {
  td <- count_measure_tool()
  args <- validate_measure_args(
    td,
    list(region = c("EMEA"), revenue_under = "1000")
  )

  expect_equal(args$region, "EMEA")
  expect_identical(args$revenue_under, 1000)
})

test_that("validate_measure_args rejects out-of-vocabulary enum values", {
  expect_snapshot(
    validate_measure_args(count_measure_tool(), list(region = "LATAM")),
    error = TRUE
  )
})

test_that("validate_measure_args rejects unknown arguments", {
  expect_snapshot(
    validate_measure_args(count_measure_tool(), list(nope = 1)),
    error = TRUE
  )
})

test_that("validate_measure_args enforces required arguments", {
  td <- ellmer::tool(
    function(x) x,
    "needs x",
    arguments = list(x = ellmer::type_string()),
    name = "needs_x"
  )
  expect_snapshot(validate_measure_args(td, list()), error = TRUE)
})

test_that("search_measures_text surfaces matches with their schema", {
  registry <- list(order_count = count_measure_tool())
  out <- search_measures_text(registry, "how many orders")

  expect_match(out, "order_count")
  expect_match(out, "revenue_under")
  expect_match(out, "EMEA")
})

test_that("search_measures_text reports when nothing matches", {
  registry <- list(order_count = count_measure_tool())
  expect_match(
    search_measures_text(registry, "weather forecast"),
    "No measure"
  )
})

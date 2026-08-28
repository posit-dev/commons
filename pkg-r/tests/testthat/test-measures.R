test_that("semantic_layer stores measures by name", {
  layer <- semantic_layer(count_measure_tool())

  expect_s3_class(layer, "commons_semantic_layer")
  expect_named(layer$measures, "order_count")
})

test_that("semantic_layer accepts a list of measures", {
  layer <- semantic_layer(list(count_measure_tool()))

  expect_named(layer$measures, "order_count")
})

test_that("semantic_layer validates its measures", {
  expect_snapshot(semantic_layer(2026), error = TRUE)
  expect_snapshot(
    semantic_layer(count_measure_tool(), count_measure_tool()),
    error = TRUE
  )
})

test_that("semantic_layer reads measures from path inputs", {
  skip_if_not_installed("roxygen2")

  path <- withr::local_tempfile(fileext = ".R")
  writeLines(
    c("#' Counter", "#' @description Counts.", "#' @measure", "counter <- function() 1L"),
    path
  )

  layer <- semantic_layer(path, count_measure_tool())

  expect_named(layer$measures, c("counter", "order_count"))
})

test_that("semantic_layer surfaces read_measures errors for bad paths", {
  expect_snapshot(semantic_layer("not a measure"), error = TRUE)
})

test_that("semantic_layer collects sources from files and inline measures", {
  skip_if_not_installed("roxygen2")

  path <- withr::local_tempfile(fileext = ".R")
  writeLines(
    c(
      "double <- function(x) x * 2L",
      "#' Counter",
      "#' @description Counts.",
      "#' @measure",
      "counter <- function() double(1L)"
    ),
    path
  )

  layer <- semantic_layer(path, count_measure_tool())

  expect_setequal(names(layer$fn_sources), c("double", "counter", "order_count"))
  expect_match(layer$fn_sources[["double"]], "x * 2L", fixed = TRUE)
  expect_match(layer$fn_sources[["order_count"]], "^function")
})

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

test_that("search_pool_text surfaces matches with their schema", {
  registry <- list(order_count = count_measure_tool())
  out <- search_pool_text(registry, empty_definitions(), "how many orders")

  expect_match(out, "order_count")
  expect_match(out, "revenue_under")
  expect_match(out, "EMEA")
})

test_that("search_pool_text omits arguments for measures without them", {
  registry <- list(
    biodiversity_by_site = measure(
      "biodiversity_by_site",
      "Species richness for every site.",
      function() NULL
    )
  )

  out <- search_pool_text(registry, empty_definitions(), "biodiversity by site")

  expect_no_match(out, "arguments:", fixed = TRUE)
  expect_no_match(out, "no arguments", fixed = TRUE)
})

test_that("search_pool_text notes measure sources when given source names", {
  registry <- list(
    region_revenue = measure(
      "region_revenue",
      "Total revenue for a region.",
      function(region, warehouse, cache) NULL,
      arguments = list(region = ellmer::type_string("The sales region."))
    )
  )

  out <- search_pool_text(
    registry,
    empty_definitions(),
    "revenue for a region",
    source_names = c("warehouse", "finance")
  )
  expect_match(out, "sources: warehouse", fixed = TRUE)
  expect_no_match(out, "finance")
  expect_no_match(out, "cache")

  expect_no_match(
    search_pool_text(registry, empty_definitions(), "revenue for a region"),
    "sources:"
  )
})

test_that("search_pool_text reports when nothing matches", {
  registry <- list(order_count = count_measure_tool())
  expect_match(
    search_pool_text(registry, empty_definitions(), "weather forecast"),
    "Nothing in the semantic layer"
  )
})

test_that("semantic_layer stores measures by name", {
  layer <- semantic_layer(count_measure_tool())

  expect_s3_class(layer, "commons_semantic_layer")
  expect_named(semantic_layer_state(layer)$measures, "order_count")
})

test_that("semantic_layer accepts a list of measures", {
  layer <- semantic_layer(list(count_measure_tool()))

  expect_named(semantic_layer_state(layer)$measures, "order_count")
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

  expect_named(semantic_layer_state(layer)$measures, c("counter", "order_count"))
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

  expect_setequal(names(semantic_layer_state(layer)$fn_sources), c("double", "counter", "order_count"))
  expect_match(semantic_layer_state(layer)$fn_sources[["double"]], "x * 2L", fixed = TRUE)
  expect_match(semantic_layer_state(layer)$fn_sources[["order_count"]], "^function")
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

fixture_scalar_type <- function(kind, description = "", required = TRUE) {
  switch(
    kind,
    integer = ellmer::type_integer(description, required = required),
    number = ellmer::type_number(description, required = required),
    boolean = ellmer::type_boolean(description, required = required),
    ellmer::type_string(description, required = required)
  )
}

fixture_type <- function(arg) {
  required <- isTRUE(arg$required)
  if (identical(arg$type, "enum")) {
    return(ellmer::type_enum(
      values = unlist(arg$values),
      description = arg$description,
      required = required
    ))
  }
  if (identical(arg$type, "array")) {
    items <- if (identical(arg$items$type, "enum")) {
      ellmer::type_enum(values = unlist(arg$items$values))
    } else {
      fixture_scalar_type(arg$items$type)
    }
    return(ellmer::type_array(
      items = items,
      description = arg$description,
      required = required
    ))
  }
  fixture_scalar_type(arg$type, arg$description, required)
}

# Build a measure from a fixture spec. The injected arguments only have to
# exist as formals; measure() marks them as hidden from the model.
fixture_measure <- function(spec) {
  arguments <- list()
  for (arg in spec$arguments) {
    arguments[[arg$name]] <- fixture_type(arg)
  }
  formal_names <- c(names(arguments), unlist(spec$injected))
  fn <- as.function(c(
    stats::setNames(rep(list(quote(expr = )), length(formal_names)), formal_names),
    list(NULL)
  ))
  measure(spec$name, spec$description, fn, arguments = arguments)
}

test_that("measure_schema_text matches the shared fixture", {
  cases <- shared_fixture("measure-schema")$measure_schema_text$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    rendered <- measure_schema_text(
      fixture_measure(case$measure),
      source_names = unlist(case$source_names) %||% character(),
      heading = case$heading %||% case$measure$name
    )
    expect_identical(rendered, case$expected, info = case$name)
  }
})

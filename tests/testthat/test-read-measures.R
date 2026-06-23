measures_script <- function(lines) {
  path <- withr::local_tempfile(fileext = ".R", .local_envir = parent.frame())
  writeLines(lines, path)
  path
}

test_that("read_measures derives a measure from a documented function", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "#' Count orders",
    "#'",
    "#' @description Total orders, optionally by region.",
    "#'",
    "#' @param region `string` The sales region.",
    "#'",
    "#' @return An integer count.",
    "order_count <- function(region = NULL) {",
    "  42L",
    "}"
  ))

  measures <- read_measures(path)

  expect_length(measures, 1)
  td <- measures[[1]]
  expect_equal(tool_name(td), "order_count")
  expect_match(tool_description(td), "Count orders")
  expect_match(tool_description(td), "Total orders")
  expect_match(tool_description(td), "Returns: An integer count")
  expect_equal(do.call(td, list()), 42L)
})

test_that("read_measures maps param type code spans to ellmer types", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "#' Measure",
    "#' @description A measure.",
    "#' @param a `string` A string.",
    "#' @param b `integer` An integer.",
    "#' @param c `number` A number.",
    "#' @param d `boolean` A boolean.",
    "#' @param e `enum[x, y, z]` An enum.",
    "#' @param f `string[]` An array.",
    "m <- function(a, b, c, d, e, f) NULL"
  ))

  props <- tool_properties(read_measures(path)[[1]])

  expect_equal(type_kind(props$a), "string")
  expect_equal(type_kind(props$b), "integer")
  expect_equal(type_kind(props$c), "number")
  expect_equal(type_kind(props$d), "boolean")
  expect_equal(type_kind(props$e), "enum")
  expect_equal(type_values(props$e), c("x", "y", "z"))
  expect_equal(type_kind(props$f), "array")
  expect_equal(type_kind(S7::prop(props$f, "items")), "string")
})

test_that("read_measures derives required from the signature, not the type", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "#' Measure",
    "#' @description A measure.",
    "#' @param required_arg `string` Required.",
    "#' @param optional_arg `string` Optional.",
    "m <- function(required_arg, optional_arg = NULL) NULL"
  ))

  props <- tool_properties(read_measures(path)[[1]])

  expect_true(S7::prop(props$required_arg, "required"))
  expect_false(S7::prop(props$optional_arg, "required"))
})

test_that("read_measures uses the param text as the type description", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "#' Measure",
    "#' @description A measure.",
    "#' @param region `string` The sales region.",
    "m <- function(region) NULL"
  ))

  props <- tool_properties(read_measures(path)[[1]])
  expect_equal(S7::prop(props$region, "description"), "The sales region.")
})

test_that("read_measures infers untyped args from their defaults", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "#' Measure",
    "#' @description A measure.",
    "#' @param i An integer default.",
    "#' @param n A number default.",
    "#' @param b A boolean default.",
    "#' @param s No default.",
    "m <- function(i = 10L, n = 1.5, b = TRUE, s) NULL"
  ))

  props <- tool_properties(read_measures(path)[[1]])

  expect_equal(type_kind(props$i), "integer")
  expect_equal(type_kind(props$n), "number")
  expect_equal(type_kind(props$b), "boolean")
  expect_equal(type_kind(props$s), "string")
})

test_that("read_measures ignores undocumented functions", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "#' Measure",
    "#' @description A measure.",
    "#' @param a `string` An arg.",
    "m <- function(a) NULL",
    "",
    "helper <- function(x) x"
  ))

  measures <- read_measures(path)

  expect_length(measures, 1)
  expect_equal(tool_name(measures[[1]]), "m")
})

test_that("read_measures reads multiple files and directories", {
  skip_if_not_installed("roxygen2")

  dir <- withr::local_tempdir()
  writeLines(
    c("#' One", "#' @description First.", "one <- function() 1L"),
    file.path(dir, "one.R")
  )
  writeLines(
    c("#' Two", "#' @description Second.", "two <- function() 2L"),
    file.path(dir, "two.R")
  )

  measures <- read_measures(dir)

  expect_setequal(vapply(measures, tool_name, character(1)), c("one", "two"))
})

test_that("read_measures produces measures usable in a semantic_layer", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "#' Count orders",
    "#' @description Counts orders.",
    "#' @param region `enum[EMEA, APAC]` The region.",
    "order_count <- function(region) 7L"
  ))

  layer <- semantic_layer(read_measures(path))

  expect_s3_class(layer, "commons_semantic_layer")
  expect_named(layer$measures, "order_count")
})

test_that("read_measures validates its inputs", {
  expect_snapshot(read_measures(123), error = TRUE)
  expect_snapshot(read_measures("does-not-exist.R"), error = TRUE)
})

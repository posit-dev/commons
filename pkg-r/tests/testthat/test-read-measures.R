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
    "#' @measure",
    "order_count <- function(region = NULL) {",
    "  2026L",
    "}"
  ))

  measures <- read_measures(path)

  expect_length(measures, 1)
  td <- measures[[1]]
  expect_equal(tool_name(td), "order_count")
  expect_match(tool_description(td), "Count orders")
  expect_match(tool_description(td), "Total orders")
  expect_match(tool_description(td), "Returns: An integer count")
  expect_equal(do.call(td, list()), 2026L)
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
    "#' @measure",
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
    "#' @measure",
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
    "#' @measure",
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
    "#' @measure",
    "m <- function(i = 10L, n = 1.5, b = TRUE, s) NULL"
  ))

  props <- tool_properties(read_measures(path)[[1]])

  expect_equal(type_kind(props$i), "integer")
  expect_equal(type_kind(props$n), "number")
  expect_equal(type_kind(props$b), "boolean")
  expect_equal(type_kind(props$s), "string")
})

test_that("read_measures treats formals without @param as injection parameters", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "#' Measure",
    "#' @description A measure.",
    "#' @param region `string` The region.",
    "#' @measure",
    "m <- function(region, warehouse, board) NULL"
  ))

  td <- read_measures(path)[[1]]

  expect_named(tool_properties(td), "region")
  expect_equal(measure_injection_names(td), c("warehouse", "board"))
})

test_that("read_measures ignores undocumented and untagged functions", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "#' Measure",
    "#' @description A measure.",
    "#' @param a `string` An arg.",
    "#' @measure",
    "m <- function(a) NULL",
    "",
    "#' Documented helper",
    "#' @description Documented but not a measure.",
    "documented_helper <- function(x) x",
    "",
    "helper <- function(x) x"
  ))

  measures <- read_measures(path)

  expect_length(measures, 1)
  expect_equal(tool_name(measures[[1]]), "m")
})

test_that("read_measures returns only @measure functions", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "#' Tagged",
    "#' @description Tagged measure.",
    "#' @measure",
    "tagged <- function() 1L",
    "",
    "#' Untagged",
    "#' @description Documented but not tagged.",
    "untagged <- function() 2L"
  ))

  measures <- read_measures(path)

  expect_length(measures, 1)
  expect_equal(tool_name(measures[[1]]), "tagged")
})

test_that("read_measures shares an env across files in one call", {
  skip_if_not_installed("roxygen2")

  dir <- withr::local_tempdir()
  a <- file.path(dir, "a.R")
  b <- file.path(dir, "b.R")
  writeLines(
    c("helper <- function(x) x * 2L"),
    a
  )
  writeLines(
    c(
      "#' Uses helper",
      "#' @description Calls a helper from a sibling file.",
      "#' @measure",
      "uses_helper <- function() helper(1013L)"
    ),
    b
  )

  measures <- read_measures(c(a, b))

  expect_length(measures, 1)
  td <- measures[[1]]
  expect_equal(tool_name(td), "uses_helper")
  expect_equal(do.call(td, list()), 2026L)
})

test_that("semantic_layer isolates measures read from separate path args", {
  skip_if_not_installed("roxygen2")

  dir <- withr::local_tempdir()
  a <- file.path(dir, "a.R")
  b <- file.path(dir, "b.R")
  writeLines(
    c("helper <- function(x) x * 2L"),
    a
  )
  writeLines(
    c(
      "#' Uses helper",
      "#' @description Calls a helper from another file.",
      "#' @measure",
      "uses_helper <- function() helper(1013L)"
    ),
    b
  )

  layer <- semantic_layer(a, b)

  expect_named(layer$measures, "uses_helper")
  expect_error(do.call(layer$measures$uses_helper, list()))
})

test_that("read_measures reads multiple files and directories", {
  skip_if_not_installed("roxygen2")

  dir <- withr::local_tempdir()
  writeLines(
    c("#' One", "#' @description First.", "#' @measure", "one <- function() 1L"),
    file.path(dir, "one.R")
  )
  writeLines(
    c("#' Two", "#' @description Second.", "#' @measure", "two <- function() 2L"),
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
    "#' @measure",
    "order_count <- function(region) 7L"
  ))

  layer <- semantic_layer(read_measures(path))

  expect_s3_class(layer, "commons_semantic_layer")
  expect_named(layer$measures, "order_count")
})

test_that("read_measures harvests measure and helper sources, comments included", {
  skip_if_not_installed("roxygen2")

  path <- measures_script(c(
    "double <- function(x) {",
    "  # helpers ride along",
    "  x * 2L",
    "}",
    "",
    "#' Count orders",
    "#' @description Counts orders.",
    "#' @measure",
    "order_count <- function() double(1013L)"
  ))

  measures <- read_measures(path)

  sources <- attr(measures, "fn_sources")
  expect_named(sources, c("double", "order_count"))
  expect_match(sources[["double"]], "# helpers ride along", fixed = TRUE)
  expect_match(sources[["order_count"]], "double(1013L)", fixed = TRUE)
})

test_that("read_measures parses @provenance tags without changing the measure", {
  skip_if_not_installed("roxygen2")

  base <- measures_script(c(
    "#' Revenue",
    "#' @description Quarterly revenue.",
    "#' @param quarter `string` The quarter.",
    "#' @measure",
    "revenue <- function(quarter) 1L"
  ))
  tagged <- measures_script(c(
    "#' Revenue",
    "#' @description Quarterly revenue.",
    "#' @param quarter `string` The quarter.",
    "#' @provenance https://github.com/org/app/blob/abc1234/R/server.R#L1-L9",
    "#' @provenance trajectory analysis (2026-07-09)",
    "#' @measure",
    "revenue <- function(quarter) 1L"
  ))

  base_measure <- expect_no_warning(read_measures(base)[[1]])
  tagged_measure <- expect_no_warning(read_measures(tagged)[[1]])

  expect_equal(tool_name(tagged_measure), tool_name(base_measure))
  expect_equal(
    tool_description(tagged_measure),
    tool_description(base_measure)
  )
  expect_equal(
    names(tool_properties(tagged_measure)),
    names(tool_properties(base_measure))
  )
  expect_identical(
    attr(tagged_measure, "commons_provenance"),
    c(
      "https://github.com/org/app/blob/abc1234/R/server.R#L1-L9",
      "trajectory analysis (2026-07-09)"
    )
  )
})

test_that("read_measures validates its inputs", {
  expect_snapshot(read_measures(123), error = TRUE)
  expect_snapshot(read_measures("does-not-exist.R"), error = TRUE)
})

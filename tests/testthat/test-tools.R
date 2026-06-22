test_that("call_measure_tool runs a measure and tags the result", {
  registry <- list(order_count = count_measure_tool())
  res <- call_measure_tool(
    registry,
    "order_count",
    arguments = jsonlite::toJSON(
      list(region = c("EMEA"), revenue_under = 1000),
      auto_unbox = TRUE
    )
  )

  expect_s7_class(res, ellmer::ContentToolResult)
  expect_equal(res@value, "2")
  expect_equal(res@extra$commons_tag, "A")
  expect_match(res@extra$display$title, "Registered measure \\(A\\)")
})

test_that("call_measure_tool errors for an unknown measure name", {
  expect_snapshot(call_measure_tool(list(), "nope", "{}"), error = TRUE)
})

test_that("run_sql_tool runs SQL and tags the result", {
  res <- run_sql_tool(test_source(), "SELECT count(*) AS n FROM sales")

  expect_s7_class(res, ellmer::ContentToolResult)
  expect_match(res@value, "6")
  expect_equal(res@extra$commons_tag, "B")
  expect_match(res@extra$display$title, "SQL query \\(B\\)")
})

test_that("format_measure_value collects a lazy dbplyr table", {
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("dplyr")

  src <- test_source()
  lazy <- dplyr::tbl(src$con, "sales")
  expect_s3_class(lazy, "tbl_sql")

  out <- format_measure_value(dplyr::filter(lazy, region == "EMEA"))
  expect_match(out, "EMEA")
})

test_that("describe_table_tool reports columns and samples", {
  res <- describe_table_tool(test_source(), "sales")
  expect_match(res@value, "order_id")
  expect_match(res@value, "Sample rows")
})

test_that("search_context_tool handles a missing context layer", {
  expect_match(search_context_tool(NULL, "anything"), "No context layer")
})

test_that("parse_json_args handles empty, brace, and object input", {
  expect_equal(parse_json_args("{}"), list())
  expect_equal(parse_json_args(""), list())
  expect_equal(parse_json_args('{"a":1}'), list(a = 1))
})

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
  expect_equal(res@extra$display$title, "Ran a trusted calculation")
  expect_false(res@extra$display$show_request)
  expect_match(res@extra$display$html, "Region:")
  expect_match(res@extra$display$html, "EMEA")
  expect_match(res@extra$display$html, "Revenue under:")
  expect_match(res@extra$display$html, "1,000")
  expect_match(res@extra$display$html, "Tool result")
  expect_match(res@extra$display$html, "2")
})

test_that("call_measure_tool uses the trusted calculation result title", {
  registry <- list(
    order_count = measure(
      "order_count",
      "Count orders.",
      function() 2,
      title = "Order count"
    )
  )

  res <- call_measure_tool(registry, "order_count", "{}")

  expect_equal(res@extra$display$title, "Ran a trusted calculation")
  expect_match(res@extra$display$html, "No arguments")
})

test_that("call_measure_tool registers tabular output as a handle", {
  registry <- list(
    orders = measure(
      "orders",
      "Orders.",
      function() test_sales(),
      arguments = list()
    )
  )
  store <- new_handle_store()

  res <- call_measure_tool(registry, "orders", "{}", handles = store)

  expect_equal(res@extra$commons_tag, "A")
  expect_match(res@value, "Available to `run_r` as `r1`", fixed = TRUE)
  expect_match(res@value, "A data frame with 6 rows and 5 columns")
  expect_match(res@value, "revenue: numeric")
  expect_equal(get_handle(store, "r1"), test_sales())
})

test_that("call_measure_tool registers scalar output as a handle", {
  registry <- list(order_count = count_measure_tool())
  store <- new_handle_store()

  res <- call_measure_tool(registry, "order_count", "{}", handles = store)

  expect_match(res@value, "Available to `run_r` as `r1`", fixed = TRUE)
  expect_equal(get_handle(store, "r1"), 6L)
  expect_identical(res@extra$display$open, FALSE)
})

test_that("call_measure_tool supports custom ContentToolResult values", {
  table <- data.frame(term = "Headache", count = 7)
  display <- shinychat::tool_result_display(
    html = htmltools::tags$table(
      htmltools::tags$tr(
        htmltools::tags$td("Headache"),
        htmltools::tags$td("7")
      )
    ),
    open = TRUE
  )
  registry <- list(
    table = measure(
      "table",
      "Summarize adverse events.",
      function() {
        ellmer::ContentToolResult(
          value = "Headache: 7",
          extra = list(
            display = display,
            data = table,
            custom = "preserved"
          )
        )
      },
      title = "Adverse events & outcomes"
    )
  )
  store <- new_handle_store()

  res <- call_measure_tool(registry, "table", "{}", handles = store)

  expect_match(
    res@value,
    "This measure result is already visible to the user",
    fixed = TRUE
  )
  expect_match(res@value, "Do not recreate or repeat it", fixed = TRUE)
  expect_match(res@value, "Headache: 7", fixed = TRUE)
  expect_match(res@value, "Available to `run_r` as `r1`", fixed = TRUE)
  expect_identical(get_handle(store, "r1"), table)
  expect_null(res@extra$data)
  expect_identical(res@extra$custom, "preserved")
  expect_identical(res@extra$display$html, display$html)
  expect_identical(res@extra$display$open, TRUE)
  expect_identical(
    res@extra$display$title,
    "Ran a trusted calculation"
  )
  expect_equal(res@extra$commons_tag, "A")
})

test_that("call_measure_tool preserves image content in ContentToolResult", {
  image <- ellmer::ContentImageInline("image/png", "YWJj")
  data <- data.frame(x = 1)
  registry <- list(
    image = measure(
      "image",
      "Return an image.",
      function() {
        ellmer::ContentToolResult(
          value = image,
          extra = list(data = data)
        )
      }
    )
  )
  store <- new_handle_store()

  res <- call_measure_tool(registry, "image", "{}", handles = store)

  expect_length(res@value, 2)
  expect_identical(res@value[[1]], image)
  expect_s7_class(res@value[[2]], ellmer::ContentText)
  expect_match(
    res@value[[2]]@text,
    "Available to `run_r` as `r1`",
    fixed = TRUE
  )
  expect_identical(get_handle(store, "r1"), data)
  expect_null(res@extra$data)
  expect_identical(res@extra$display$title, "Ran a trusted calculation")
})

test_that("call_measure_tool preserves custom ContentToolResult errors", {
  registry <- list(
    error = measure(
      "error",
      "Return an authored error.",
      function() {
        ellmer::ContentToolResult(
          error = "authored error",
          extra = list(data = structure(list(), class = "tbl_sql"))
        )
      }
    )
  )
  store <- new_handle_store()

  res <- call_measure_tool(registry, "error", "{}", handles = store)

  expect_identical(res@error, "authored error")
  expect_null(res@extra$data)
  expect_length(handle_ids(store), 0)
})

test_that("call_measure_tool shows ggplot results to the model and user", {
  skip_if_not_installed("ggplot2")
  plot <- ggplot2::ggplot()
  registry <- list(
    plot = measure(
      "plot",
      "Plot values.",
      function() plot,
      title = 'A & "B"'
    )
  )
  store <- new_handle_store()

  res <- call_measure_tool(registry, "plot", "{}", handles = store)

  images <- Filter(
    \(x) S7::S7_inherits(x, ellmer::ContentImageInline),
    res@value
  )

  expect_length(images, 1)
  notes <- Filter(
    \(x) S7::S7_inherits(x, ellmer::ContentText),
    res@value
  )
  expect_true(any(vapply(
    notes,
    \(x) grepl("This plot is already visible to the user", x@text, fixed = TRUE),
    logical(1)
  )))
  expect_match(
    res@extra$display$html,
    'alt="Plot returned by A &amp; &quot;B&quot;"',
    fixed = TRUE
  )
  expect_s3_class(get_handle(store, "r1"), "ggplot")
  expect_identical(res@extra$display$open, TRUE)
})

test_that("call_measure_tool shows gt tables to the model and user", {
  skip_if_not_installed("gt")
  table_data <- data.frame(term = "Headache", count = 7)
  table <- gt::opt_interactive(gt::gt(table_data))
  registry <- list(
    table = measure(
      "table",
      "Summarize adverse events.",
      function() table
    )
  )
  store <- new_handle_store()

  res <- call_measure_tool(registry, "table", "{}", handles = store)

  expect_match(
    res@value,
    "This gt table is already visible to the user",
    fixed = TRUE
  )
  expect_match(
    res@value,
    "For calculations, use `run_r` with the table handle below",
    fixed = TRUE
  )
  expect_match(res@value, "Headache", fixed = TRUE)
  expect_no_match(res@value, "<table>", fixed = TRUE)
  expect_match(res@extra$display$html, "Headache", fixed = TRUE)
  expect_gt(length(htmltools::findDependencies(res@extra$display$html)), 0)
  expect_identical(get_handle(store, "r1"), table_data)
  expect_identical(res@extra$display$open, TRUE)
})

test_that("call_measure_tool keeps recoverable table data when HTML conversion fails", {
  skip_if_not_installed("gt")
  table_data <- data.frame(term = "Headache", count = 7)
  table <- gt::gt(table_data)
  local_mocked_bindings(
    render_gt_table = function(...) stop("HTML conversion broke")
  )
  registry <- list(
    table = measure(
      "table",
      "Summarize adverse events.",
      function() table
    )
  )
  store <- new_handle_store()

  res <- call_measure_tool(registry, "table", "{}", handles = store)

  expect_match(res@value, "Headache", fixed = TRUE)
  expect_match(
    res@extra$display$html,
    "commons-measure-gt-table-error",
    fixed = TRUE
  )
  expect_identical(get_handle(store, "r1"), table_data)
  expect_identical(res@extra$display$open, TRUE)
})

test_that("call_measure_tool keeps ggplot results when display rendering fails", {
  skip_if_not_installed("ggplot2")
  local_mocked_bindings(
    render_plot_image = function(...) stop("graphics device broke")
  )
  plot <- ggplot2::ggplot()
  registry <- list(
    plot = measure(
      "plot",
      "Plot values.",
      function() plot
    )
  )
  store <- new_handle_store()

  res <- call_measure_tool(registry, "plot", "{}", handles = store)

  expect_match(res@value, "could not be displayed")
  expect_match(res@extra$display$html, "commons-measure-plot-error")
  expect_s3_class(get_handle(store, "r1"), "ggplot")
})

test_that("register_handle numbers handles in call order and caps rows", {
  store <- new_handle_store()

  first <- register_handle(store, test_sales())
  second <- register_handle(store, test_sales(), max_rows = 2)

  expect_match(first, "`r1`")
  expect_match(second, "`r2`")
  expect_match(second, "Only the first 2 rows are stored")
  expect_equal(handle_ids(store), c("r1", "r2"))
  expect_equal(nrow(get_handle(store, "r2")), 2)
})

test_that("call_measure_tool errors for an unknown measure name", {
  expect_snapshot(call_measure_tool(list(), "nope", "{}"), error = TRUE)
})

test_that("run_sql_tool runs SQL and tags the result", {
  res <- run_sql_tool(test_source(), "SELECT count(*) AS n FROM sales")

  expect_s7_class(res, ellmer::ContentToolResult)
  expect_match(res@value, "6")
  expect_equal(res@extra$commons_tag, "B")
  expect_equal(res@extra$display$title, "Retrieved data")
  expect_false(res@extra$display$open)
  expect_false(res@extra$display$show_request)
  expect_match(res@extra$display$markdown, "```sql")
  expect_match(res@extra$display$markdown, "SELECT count")
})

test_that("run_sql_tool registers its result as a handle", {
  store <- new_handle_store()
  res <- run_sql_tool(
    test_source(),
    "SELECT region, sum(revenue) AS revenue FROM sales GROUP BY region",
    handles = store
  )

  expect_match(res@value, "Available to `run_r` as `r1`", fixed = TRUE)
  expect_equal(nrow(get_handle(store, "r1")), 3)
})

test_that("format_measure_value collects a lazy dbplyr table", {
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("dplyr")

  src <- test_source()
  lazy <- dplyr::tbl(data_source_state(src)$con, "sales")
  expect_s3_class(lazy, "tbl_sql")

  out <- format_measure_value(dplyr::filter(lazy, region == "EMEA"))
  expect_match(out, "EMEA")
})

test_that("describe_table_tool reports columns and samples", {
  res <- describe_table_tool(test_source(), "sales")
  expect_equal(res@extra$display$title, "Inspected a table")
  expect_match(res@value, "order_id")
  expect_match(res@value, "Sample summary")
  expect_match(
    res@value,
    '* order_id: character with 0 NAs, and 5 unique values',
    fixed = TRUE
  )
})

test_that("search_context_tool handles a missing context layer", {
  expect_match(search_context_tool(NULL, "anything"), "No context layer")
})

test_that("parse_json_args handles empty, brace, and object input", {
  expect_equal(parse_json_args("{}"), list())
  expect_equal(parse_json_args(""), list())
  expect_equal(parse_json_args('{"a":1}'), list(a = 1))
})

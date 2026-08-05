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
  expect_equal(res@extra$display$title, "Ran a trusted calculation: order count")
  expect_false(res@extra$display$show_request)
  expect_match(res@extra$display$html, "Region:")
  expect_match(res@extra$display$html, "EMEA")
  expect_match(res@extra$display$html, "Revenue under:")
  expect_match(res@extra$display$html, "1,000")
  expect_match(res@extra$display$html, "Tool result")
  expect_match(res@extra$display$html, "2")
})

test_that("call_measure_tool uses measure display titles", {
  registry <- list(
    order_count = measure(
      "order_count",
      "Count orders.",
      function() 2,
      title = "Order count"
    )
  )

  res <- call_measure_tool(registry, "order_count", "{}")

  expect_equal(res@extra$display$title, "Ran a trusted calculation: Order count")
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
  expect_equal(res@extra$display$title, "Grabbed data")
  expect_false(res@extra$display$open)
  expect_false(res@extra$display$show_request)
  expect_match(res@extra$display$markdown, "```sql")
  expect_match(res@extra$display$markdown, "SELECT count")
})

test_that("free-form SQL stays untrusted beside governed metadata", {
  source <- test_source()
  catalog_source <- new_catalog_source("source:test", "duckdb")
  source$catalog <- new_commons_catalog(
    sources = list(catalog_source),
    context = list(new_catalog_context(
      "context:trusted",
      catalog_source$id,
      "instruction",
      "Revenue is a certified semantic metric.",
      delivery = "retrieval",
      authority = list(kind = "certified")
    ))
  )

  result <- run_sql_tool(source, "SELECT sum(revenue) AS revenue FROM sales")

  expect_equal(result@extra$commons_tag, "B")
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
  lazy <- dplyr::tbl(src$con, "sales")
  expect_s3_class(lazy, "tbl_sql")

  out <- format_measure_value(dplyr::filter(lazy, region == "EMEA"))
  expect_match(out, "EMEA")
})

test_that("describe_table_tool reports columns without sampling by default", {
  res <- describe_table_tool(test_source(), "sales")
  expect_match(res@value, "order_id")
  expect_no_match(res@value, "Sample rows")
})

test_that("semantic context arrives only on first table touch", {
  source <- test_source()
  catalog_source <- new_catalog_source("source:test", "duckdb")
  relation <- new_catalog_relation(
    "relation:sales",
    catalog_source$id,
    new_source_path(c(table = "sales"))
  )
  model <- new_catalog_model(
    "model:sales",
    catalog_source$id,
    "sales_model",
    datasets = relation$id,
    exposed = relation$id
  )
  source$catalog <- new_commons_catalog(
    sources = list(catalog_source),
    relations = list(relation),
    models = list(model),
    context = list(new_catalog_context(
      "context:sales",
      catalog_source$id,
      "instruction",
      "Use booked revenue for sales reporting.",
      scope = model$id,
      delivery = "first_touch"
    ))
  )
  source$relation_labels <- c("relation:sales" = "sales")
  tracker <- new.env(parent = emptyenv())

  first <- describe_table_tool(source, "sales", tracker = tracker)
  second <- describe_table_tool(source, "sales", tracker = tracker)

  expect_match(first@value, "booked revenue")
  expect_no_match(second@value, "booked revenue")
})

test_that("search_context_tool handles a missing context layer", {
  expect_match(search_context_tool(NULL, "anything"), "No context layer")
})

test_that("parse_json_args handles empty, brace, and object input", {
  expect_equal(parse_json_args("{}"), list())
  expect_equal(parse_json_args(""), list())
  expect_equal(parse_json_args('{"a":1}'), list(a = 1))
})

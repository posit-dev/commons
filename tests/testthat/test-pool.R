test_that("call_metrics compiles metrics x dimensions x filters x where", {
  store <- new_handle_store()
  query <- metrics_caller(store = store)

  res <- query(
    metrics = "big_revenue",
    dimensions = "region_band",
    filters = "emea",
    where = list(list(column = "revenue", op = ">", value = "400"))
  )

  expect_equal(res@extra$commons_tag, "A")
  # emea filters to EMEA rows, so only the 'east' band appears; revenues
  # over 400 and 600 leave 1200 + 750.
  value <- get_handle(store, "r1")
  expect_equal(value$region_band, "east")
  expect_equal(value$big_revenue, 1950)
  expect_match(res@extra$display$markdown, "GROUP BY", fixed = TRUE)
})

test_that("call_metrics groups by documented columns too", {
  store <- new_handle_store()
  metrics_caller(store = store)(
    metrics = "big_revenue",
    dimensions = "region"
  )

  value <- get_handle(store, "r1")
  expect_setequal(value$region, c("Americas", "APAC", "EMEA"))
  expect_equal(value$big_revenue[value$region == "EMEA"], 1950)
})

test_that("call_metrics without dimensions returns a grand total", {
  store <- new_handle_store()
  metrics_caller(store = store)(metrics = "big_revenue")
  expect_equal(get_handle(store, "r1")$big_revenue, 1950)
})

test_that("names arriving in token braces are accepted", {
  store <- new_handle_store()
  metrics_caller(store = store)(
    metrics = "{{big_revenue}}",
    dimensions = "{{region_band}}",
    filters = "{{emea}}"
  )

  value <- get_handle(store, "r1")
  expect_equal(value$big_revenue[value$region_band == "east"], 1950)
})

test_that("call_metrics validates names with actionable errors", {
  query <- metrics_caller()

  expect_error(query(metrics = "nope"), "No governed metric is named")
  expect_error(query(metrics = "region_band"), "is a dimension, not a metric")
  expect_error(
    query(metrics = "big_revenue", dimensions = "nope"),
    "No dimension or documented column"
  )
  expect_error(
    query(metrics = "big_revenue", filters = "region_band"),
    "is a dimension, not a filter"
  )
  expect_error(
    query(
      metrics = "big_revenue",
      where = list(list(column = "nope", op = "=", value = "1"))
    ),
    "not a\\s+documented column"
  )
  expect_error(
    query(
      metrics = "big_revenue",
      where = list(list(column = "revenue", op = "LIKE", value = "1"))
    ),
    "operator"
  )
})

test_that("metrics in one call must share a table", {
  path <- withr::local_tempfile(fileext = ".yaml")
  writeLines(
    c(
      "tables:",
      "  - name: sales",
      "    definitions:",
      "      - name: total_revenue",
      "        type: number(quantity)",
      "        expr: SUM(revenue)",
      "  - name: reps",
      "    definitions:",
      "      - name: n_reps",
      "        type: number(quantity)",
      "        expr: COUNT(*)"
    ),
    path
  )
  src <- data_source(
    sales = test_sales(),
    reps = data.frame(rep = "Ada"),
    dictionary = path
  )
  store <- new_handle_store()
  query <- metrics_caller(src, store)

  expect_error(
    query(metrics = c("total_revenue", "n_reps")),
    "must share a table"
  )
  query(metrics = "total_revenue")
  expect_equal(get_handle(store, "r1")$total_revenue, sum(test_sales()$revenue))
})

test_that("call_metrics quotes string predicates and passes numbers through", {
  query <- metrics_caller(store = new_handle_store())

  res <- query(
    metrics = "big_revenue",
    where = list(list(column = "region", op = "=", value = "EMEA"))
  )
  expect_match(res@extra$display$markdown, "'EMEA'", fixed = TRUE)

  res <- query(
    metrics = "big_revenue",
    where = list(list(column = "revenue", op = "<", value = "1000"))
  )
  expect_match(res@extra$display$markdown, "< 1000", fixed = TRUE)
})

test_that("board-source metrics resolve their role at first query", {
  board <- board_with_pins(sales = test_sales())
  src <- data_source(
    board,
    tables = c(sales = "sales"),
    dictionary = local_definitions_dict()
  )
  registry <- definitions_registry(list(sales_db = src))
  validate_eager_definitions(registry, list(sales_db = src))
  expect_true(is.na(registry_defs(registry)$role[[2]]))

  store <- new_handle_store()
  call_metrics_impl(
    registry,
    list(sales_db = src),
    store,
    metrics = "big_revenue"
  )
  expect_equal(get_handle(store, "r1")$big_revenue, 1950)
})

test_that("the pool tools follow the agent's composition", {
  tool_names <- function(agent) {
    vapply(agent$get_tools(), tool_name, character(1))
  }

  # Definitions with metrics, all ambient in the prompt: call_metrics but no
  # search_pool (a search over a fully visible pool is a wasted trip) and no
  # call_measure.
  definitions_agent <- test_agent(
    data_sources = list(sales_db = definitions_source())
  )
  expect_true("call_metrics" %in% tool_names(definitions_agent))
  expect_false(any(
    c("search_pool", "call_measure") %in% tool_names(definitions_agent)
  ))
  expect_match(
    definitions_agent$get_system_prompt(),
    "the complete set of governed definitions"
  )

  # Filters only: no call_metrics either.
  filters_only <- test_agent(
    data_sources = list(
      sales_db = definitions_source(
        definitions = c(
          "      - name: emea",
          "        type: boolean",
          "        expr: region = 'EMEA'"
        )
      )
    )
  )
  expect_false(any(
    c("search_pool", "call_metrics") %in% tool_names(filters_only)
  ))

  # A roster past the ambient cap makes the pool searchable.
  overflow_agent <- test_agent(
    data_sources = list(sales_db = definitions_source(many_definitions()))
  )
  expect_true("search_pool" %in% tool_names(overflow_agent))

  # Measures only: search_pool + call_measure (measures are never listed in
  # the prompt), no call_metrics.
  measures_agent <- test_agent(
    semantic_layer = semantic_layer(count_measure_tool())
  )
  expect_true(all(
    c("search_pool", "call_measure") %in% tool_names(measures_agent)
  ))
  expect_false("call_metrics" %in% tool_names(measures_agent))

  # Neither: no pool surface at all.
  expect_false(any(
    c("search_pool", "call_measure", "call_metrics") %in%
      tool_names(test_agent())
  ))
})

test_that("search_pool spans measures and definitions", {
  registry <- validated_registry(definitions_source())
  measures <- list(order_count = count_measure_tool())

  out <- search_pool_text(measures, registry, "revenue in EMEA")
  expect_match(out, "{{big_revenue}} --- metric on table `sales`", fixed = TRUE)
  expect_match(out, "call_metrics", fixed = TRUE)
  # A metric hit advertises what it can be sliced by.
  expect_match(out, "Filters and dimensions on this table", fixed = TRUE)
  expect_match(out, "{{emea}} (filter)", fixed = TRUE)

  out <- search_pool_text(measures, registry, "how many orders")
  expect_match(out, "### order_count", fixed = TRUE)
})

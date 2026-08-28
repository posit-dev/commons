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
  expect_identical(res@extra$display$label, "big revenue")
  expect_identical(res@extra$display$value_preview, "1 row × 2 columns")
  expect_match(
    res@extra$display$html,
    "Revenue over big EMEA orders.",
    fixed = TRUE
  )
  expect_match(res@value, "Applied governed definitions", fixed = TRUE)
  expect_match(res@value, "Translation notes", fixed = TRUE)
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

test_that("call_metrics groups by filter definitions", {
  store <- new_handle_store()
  metrics_caller(store = store)(
    metrics = "big_revenue",
    dimensions = "emea"
  )

  value <- get_handle(store, "r1")
  expect_setequal(value$emea, c(FALSE, TRUE))
  expect_equal(value$big_revenue[value$emea], 1950)
})

test_that("call_metrics without dimensions returns a grand total", {
  store <- new_handle_store()
  metrics_caller(store = store)(metrics = "big_revenue")
  expect_equal(get_handle(store, "r1")$big_revenue, 1950)
})

test_that("constant metrics return one row when no input rows remain", {
  src <- definitions_source(
    definitions = c(
      "      - name: answer",
      "        expr: \"42\"",
      "      - name: total_revenue",
      "        expr: SUM(revenue)"
    )
  )
  store <- new_handle_store()
  query <- metrics_caller(src, store)

  query(
    metrics = c("answer", "total_revenue"),
    where = list(list(column = "revenue", op = ">", value = "9999"))
  )

  value <- get_handle(store, "r1")
  expect_equal(nrow(value), 1L)
  expect_equal(value$answer, 42)
  expect_true(is.na(value$total_revenue))

  empty <- data_source(
    sales = test_sales()[0, ],
    dictionary = local_definitions_dict(
      definitions = c(
        "      - name: answer",
        "        expr: \"42\""
      )
    )
  )
  store <- new_handle_store()

  metrics_caller(empty, store)(metrics = "answer")

  value <- get_handle(store, "r1")
  expect_equal(nrow(value), 1L)
  expect_equal(value$answer, 42)
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
  expect_error(query(metrics = "region_band"), "is a derived, not a metric")
  expect_error(
    query(metrics = "big_revenue", dimensions = "nope"),
    "No dimension or documented column"
  )
  expect_error(
    query(metrics = "big_revenue", filters = "region_band"),
    "is a derived, not a filter"
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
      "    columns:",
      "      - name: revenue",
      "        type: number",
      "    definitions:",
      "      - name: total_revenue",
      "        expr: SUM(revenue)",
      "  - name: reps",
      "    definitions:",
      "      - name: n_reps",
      "        expr: ROW_COUNT()"
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

test_that("board-source metrics query without pre-binding the board", {
  board <- board_with_pins(sales = test_sales())
  src <- data_source(
    board,
    tables = c(sales = "sales"),
    dictionary = local_definitions_dict()
  )
  registry <- definitions_registry(list(sales_db = src))
  expect_equal(registry_defs(registry)$kind[[2]], "metric")

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
  expect_match(
    definitions_agent$get_system_prompt(),
    "Result values from `call_metrics`",
    fixed = TRUE
  )

  # Filters only: no call_metrics either.
  filters_only <- test_agent(
    data_sources = list(
      sales_db = definitions_source(
        definitions = c(
          "      - name: emea",
          "        expr: region = 'EMEA'"
        )
      )
    )
  )
  expect_false(any(
    c("search_pool", "call_metrics") %in% tool_names(filters_only)
  ))
  expect_no_match(
    filters_only$get_system_prompt(),
    "call_metrics",
    fixed = TRUE
  )

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

test_that("search_pool renders its results as Markdown", {
  agent <- test_agent(
    semantic_layer = semantic_layer(count_measure_tool())
  )

  result <- agent_tool(agent, "search_pool")("count orders")

  expect_identical(result@extra$display$markdown, result@value)
  expect_identical(result@extra$display$label, "count orders")
})

test_that("search_pool spans measures and definitions", {
  registry <- sales_registry(definitions_source())
  measures <- list(order_count = count_measure_tool())

  out <- search_pool_text(measures, registry, "revenue in EMEA")
  expect_match(out, "{{big_revenue}} --- metric on table `sales`", fixed = TRUE)
  expect_match(out, "call_metrics", fixed = TRUE)
  expect_no_match(out, "Expression:", fixed = TRUE)
  expect_no_match(out, "SUM(CASE WHEN emea", fixed = TRUE)
  expect_match(out, "Selected SQL(duckdb)", fixed = TRUE)
  expect_match(out, "Translation notes", fixed = TRUE)
  # A metric hit advertises what it can be sliced by.
  expect_match(
    out,
    "Filters and derived definitions on this table",
    fixed = TRUE
  )
  expect_match(out, "{{emea}} (filter)", fixed = TRUE)

  out <- search_pool_text(measures, registry, "how many orders")
  expect_match(out, "### order_count", fixed = TRUE)

  general_name <- definitions_source(
    definitions = c(
      "      - name: gross margin",
      "        expr: SUM(revenue)"
    )
  )
  out <- search_pool_text(
    list(),
    sales_registry(general_name),
    "gross margin"
  )
  expect_match(out, "SELECT {{gross margin}} AS value", fixed = TRUE)

  labelled <- definitions_source(
    definitions = c(
      "      - name: metric_1",
      "        label: Commercial contribution",
      "        expr: SUM(revenue)"
    )
  )
  out <- search_pool_text(
    list(),
    sales_registry(labelled),
    "commercial contribution"
  )
  expect_match(out, "{{metric_1}} --- metric", fixed = TRUE)
})

test_that("definition discovery only mentions available tools", {
  src <- definitions_source(
    definitions = c(
      "      - name: emea",
      "        expr: region = 'EMEA'"
    )
  )
  registry <- sales_registry(src)
  out <- definition_pool_text(registry_defs(registry), registry_defs(registry))

  expect_no_match(out, "call_metrics", fixed = TRUE)
})

test_that("call_metrics rejects mixed-grain definitions", {
  src <- definitions_source(
    definitions = c(
      "      - name: total_revenue",
      "        expr: SUM(revenue)",
      "      - name: above_minimum",
      "        expr: revenue > MIN(revenue)",
      "      - name: inherited_mixed",
      "        expr: NOT above_minimum"
    )
  )
  registry <- sales_registry(src)
  records <- registry_defs(registry)

  expect_true(records$mixed_grain[records$name == "above_minimum"])
  expect_true(records$mixed_grain[records$name == "inherited_mixed"])

  guidance <- definition_pool_text(
    records[records$name == "above_minimum", ],
    records
  )
  expect_match(guidance, "manually grain-correct", fixed = TRUE)
  expect_no_match(guidance, "call_metrics", fixed = TRUE)
  expect_no_match(guidance, "WHERE", fixed = TRUE)

  expect_error(
    call_metrics_impl(
      registry,
      list(sales_db = src),
      NULL,
      metrics = "total_revenue",
      dimensions = "above_minimum"
    ),
    "Mixed-grain definition"
  )
  expect_error(
    call_metrics_impl(
      registry,
      list(sales_db = src),
      NULL,
      metrics = "total_revenue",
      filters = "above_minimum"
    ),
    "Mixed-grain filter"
  )
  expect_error(
    call_metrics_impl(
      registry,
      list(sales_db = src),
      NULL,
      metrics = "total_revenue",
      dimensions = "inherited_mixed"
    ),
    "Mixed-grain definition"
  )

  expansion <- expand_for_run_sql(
    registry,
    list(sales_db = src),
    NULL,
    "SELECT {{above_minimum}} FROM sales"
  )
  expect_match(expansion$sql, '"revenue" > min("revenue")', fixed = TRUE)
})

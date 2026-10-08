trusted_agent <- function(...) {
  test_agent(..., mode = "trusted only")
}

mixed_grain_source <- function() {
  definitions_source(
    definitions = c(
      "      - name: total_revenue",
      "        expr: SUM(revenue)",
      "      - name: above_minimum",
      "        expr: revenue > MIN(revenue)"
    )
  )
}

test_that("a trusted-only agent registers no fallback tools", {
  agent <- trusted_agent(semantic_layer = semantic_layer(count_measure_tool()))
  private <- agent$.__enclos_env__$private

  expect_identical(
    unname(vapply(agent$get_tools(), tool_name, character(1))),
    c("search_pool", "call_measure", "search_context", "describe_table", "load_skill")
  )
  expect_null(private$worker)
  expect_null(private$handles)
  expect_null(private$citation_request)

  metrics <- trusted_agent(
    data_sources = list(sales_db = definitions_source())
  )
  expect_identical(
    unname(vapply(metrics$get_tools(), tool_name, character(1))),
    c("call_metrics", "search_context", "describe_table", "load_skill")
  )
})

test_that("a trusted-only agent needs a trusted calculation", {
  expect_snapshot(trusted_agent(), error = TRUE)
  # Filters and derived definitions alone have no trusted path.
  expect_error(
    trusted_agent(
      data_sources = list(
        sales_db = definitions_source(
          definitions = c(
            "      - name: emea",
            "        expr: region = 'EMEA'"
          )
        )
      )
    ),
    "needs at least one trusted"
  )
})

test_that("a trusted-only agent has no R session to open to the network", {
  expect_snapshot(
    trusted_agent(
      semantic_layer = semantic_layer(count_measure_tool()),
      network = "full"
    ),
    error = TRUE
  )
})

test_that("mode is validated", {
  expect_error(test_agent(mode = "strict"), "must be one of")
})

test_that("the trusted-only prompt drops the fallback path and citations", {
  prompt <- trusted_agent(
    semantic_layer = semantic_layer(count_measure_tool())
  )$get_system_prompt()

  expect_match(prompt, "Answer data questions only with trusted calculations")
  expect_no_match(prompt, "## Citations", fixed = TRUE)
  expect_no_match(prompt, "commons-citation", fixed = TRUE)
  expect_no_match(prompt, "run_sql", fixed = TRUE)
  expect_no_match(prompt, "run_r", fixed = TRUE)
})

test_that("describe_table omits sample rows and fetches none", {
  src <- definitions_source()
  agent <- trusted_agent(data_sources = list(sales_db = src))
  describe <- agent_tool(agent, "describe_table")

  expect_no_match(tool_description(describe), "sample", ignore.case = TRUE)
  body <- describe("sales")@value
  expect_no_match(body, "Sample summary", fixed = TRUE)
  expect_match(body, "revenue", fixed = TRUE)
  expect_match(body, "compute metrics with call_metrics", fixed = TRUE)
  expect_no_match(body, "tokens in SQL", fixed = TRUE)

  described <- source_describe(src, "sales", n_sample = 0)
  expect_identical(nrow(described$sample), 0L)
  expect_setequal(names(described$sample), names(test_sales()))
})

test_that("describe_table keeps the live schema of an undocumented table", {
  agent <- trusted_agent(semantic_layer = semantic_layer(count_measure_tool()))

  body <- agent_tool(agent, "describe_table")("sales")@value

  expect_no_match(body, "Sample summary", fixed = TRUE)
  for (column in names(test_sales())) {
    expect_match(body, column, fixed = TRUE)
  }
})

test_that("trusted results carry no handle for run_r", {
  agent <- trusted_agent(semantic_layer = semantic_layer(count_measure_tool()))

  result <- agent_tool(agent, "call_measure")("order_count", "{}")

  expect_no_match(result@value, "Available to", fixed = TRUE)
})

test_that("search_pool points definitions at call_metrics alone", {
  src <- definitions_source()
  agent <- trusted_agent(
    data_sources = list(sales_db = src),
    semantic_layer = semantic_layer(count_measure_tool())
  )
  search <- agent_tool(agent, "search_pool")

  expect_match(tool_description(search), "compute with call_metrics")
  expect_no_match(tool_description(search), "run_sql", fixed = TRUE)
  for (query in c("EMEA revenue", "region grouping", "nothing like this")) {
    expect_no_match(search(query)@value, "run_sql|SQL query", info = query)
  }
})

test_that("definitions without a trusted path say so", {
  records <- registry_defs(sales_registry(mixed_grain_source()))
  guidance <- definition_pool_text(
    records[records$name == "above_minimum", ],
    records,
    trusted_only = TRUE
  )
  expect_match(guidance, "No trusted calculation can use this definition.")

  filters_only <- registry_defs(sales_registry(definitions_source(
    definitions = c(
      "      - name: emea",
      "        expr: region = 'EMEA'"
    )
  )))
  expect_match(
    definition_pool_text(filters_only, filters_only, trusted_only = TRUE),
    "No trusted calculation can use this definition."
  )
})

test_that("call_metrics errors don't point at fallback tools", {
  src <- mixed_grain_source()
  call <- function(...) {
    call_metrics_impl(
      sales_registry(src),
      list(sales_db = src),
      NULL,
      metrics = "total_revenue",
      ...,
      trusted_only = TRUE
    )
  }

  expect_snapshot(call(dimensions = "above_minimum"), error = TRUE)
  expect_snapshot(call(filters = "above_minimum"), error = TRUE)
})

test_calculation <- function() {
  new_trusted_calculation(
    "preview_value",
    "Preview an allowed column with a bound value.",
    "SELECT {{column}}, {{value}} AS bound_value FROM sales LIMIT 1",
    arguments = list(
      new_typed_argument(
        "column",
        "string",
        identifier = TRUE,
        choices = c("region", "revenue")
      ),
      new_typed_argument("value", "number")
    )
  )
}

test_that("trusted calculations bind values and allowlist identifiers", {
  calculation <- test_calculation()
  prepared <- prepare_calculation(
    calculation,
    list(column = "region", value = 2),
    DBI::ANSI()
  )

  expect_equal(
    prepared$sql,
    'SELECT "region", ? AS bound_value FROM sales LIMIT 1'
  )
  expect_equal(prepared$bindings, list(2))
  expect_error(
    prepare_calculation(
      calculation,
      list(column = "secret", value = 2),
      DBI::ANSI()
    ),
    "does not allow"
  )
  expect_error(
    prepare_calculation(
      calculation,
      list(column = "region", value = "two"),
      DBI::ANSI()
    ),
    "must be a number"
  )
})

test_that("identifier arguments require explicit choices", {
  expect_error(
    new_typed_argument("column", "string", identifier = TRUE),
    "explicit allowlist"
  )
  expect_error(
    new_trusted_calculation(
      "unsafe",
      "Unsafe query.",
      "DROP TABLE {{column}}",
      list(new_typed_argument(
        "column",
        "string",
        identifier = TRUE,
        choices = "region"
      ))
    ),
    "exactly one read-only SELECT"
  )
})

test_that("trusted calculation execution is tagged after DBI binding", {
  source <- test_source()
  source$calculations <- list(test_calculation())
  sources <- list(sales_db = source)
  handles <- new_handle_store()

  result <- call_calculation_impl(
    calculations_registry(sources),
    sources,
    handles,
    "preview_value",
    '{"column":"region","value":2}'
  )

  expect_equal(get_handle(handles, "r1")$bound_value, 2)
  expect_equal(result@extra$commons_tag, "A")
})

test_that("trusted calculations are searchable and earn their tools", {
  source <- test_source()
  source$calculations <- list(test_calculation())
  registry <- calculations_registry(list(sales_db = source))

  result <- search_pool_text(
    list(),
    empty_definitions(),
    "preview allowed column",
    calculations = registry
  )
  agent <- test_agent(data_sources = list(sales_db = source))
  tools <- vapply(agent$get_tools(), tool_name, character(1))

  expect_match(result, "preview_value", fixed = TRUE)
  expect_match(result, "allowed: region, revenue", fixed = TRUE)
  expect_contains(tools, "search_pool")
  expect_contains(tools, "call_calculation")
})

test_that("verified queries retain exact SQL separately from semantic models", {
  model <- snowflake_semantic_model_from_spec(
    DBI::Id(catalog = "ANALYTICS", schema = "PUBLIC", table = "MODEL"),
    list(
      verified_queries = list(list(
        name = "top_regions",
        question = "Which regions lead revenue?",
        sql = "SELECT region, SUM(revenue) FROM orders GROUP BY region"
      ))
    )
  )
  calculations <- semantic_model_calculations(list(model = model))

  expect_length(calculations, 1L)
  expect_equal(calculations[[1]]$name, "top_regions")
  expect_equal(
    calculations[[1]]$sql,
    "SELECT region, SUM(revenue) FROM orders GROUP BY region"
  )
  expect_equal(calculations[[1]]$model, "model")
})

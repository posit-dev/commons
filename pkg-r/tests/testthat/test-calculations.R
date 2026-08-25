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

test_that("typed values retain large integers and reject malformed times", {
  integer <- new_typed_argument("value", "integer")
  expect_identical(
    validate_typed_value(2147483648, integer),
    2147483648
  )
  expect_error(
    validate_typed_value(2^53, integer),
    "must be an integer"
  )

  date <- new_typed_argument("date", "date")
  datetime <- new_typed_argument("datetime", "datetime")
  expect_identical(validate_typed_value("2024-02-29", date), "2024-02-29")
  expect_error(validate_typed_value("2024-01-01junk", date), "must be a date")
  expect_identical(
    validate_typed_value("2024-01-01T23:59:59Z", datetime),
    "2024-01-01T23:59:59Z"
  )
  expect_error(
    validate_typed_value("2024-99-99T99:99junk", datetime),
    "must be a datetime"
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
  expect_equal(result@extra$display$title, "Ran a trusted calculation")
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

test_that("lazy verified queries hydrate from qualified names", {
  source <- test_source()
  model <- test_semantic_model()
  model$calculations <- list(new_trusted_calculation(
    "top_regions",
    "Which regions lead revenue?",
    "SELECT region, SUM(revenue) FROM sales GROUP BY region"
  ))
  label <- table_id_label(model$id)
  source$semantic_stubs <- stats::setNames(list(
    new_semantic_model_stub(
      list(id = model$id, description = model$description),
      "snowflake_semantic_view"
    )
  ), label)
  sources <- list(sales_db = source)
  sql <- NULL
  local_mocked_bindings(
    snowflake_read_semantic_model = function(...) model,
    source_query_bind = function(source, query, bindings) {
      sql <<- query
      data.frame(region = "EMEA", revenue = 42)
    }
  )

  result <- call_calculation_impl(
    list(),
    sources,
    new_handle_store(),
    paste0(label, "::top_regions")
  )

  expect_equal(sql, model$calculations[[1]]$sql)
  expect_equal(result@extra$commons_tag, "A")
})

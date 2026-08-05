test_that("Apache Ossie models import into the common catalog", {
  catalog <- catalog_from_ossie(test_path("fixtures", "ossie-databricks.yaml"))
  model <- catalog$models[[1]]
  orders <- Filter(function(x) x$name == "orders", catalog$relations)[[1]]
  definitions <- Filter(
    function(x) identical(x$model_id, model$id),
    catalog$definitions
  )

  expect_equal(catalog$sources[[1]]$version, "0.2.0.dev0")
  expect_setequal(vapply(catalog$relations, `[[`, character(1), "name"), c("orders", "customer"))
  expect_setequal(
    vapply(definitions, `[[`, character(1), "name"),
    c("o_orderkey", "o_orderdate", "c_name", "total_revenue", "order_count")
  )
  expect_equal(orders$constraints[[1]]$kind, "primary_key")
  expect_equal(orders$constraints[[2]]$kind, "foreign_key")
  expect_equal(orders$constraints[[2]]$enforcement, "unknown")
  expect_true(length(catalog$context) >= 4)
  expect_true(model$extensions$databricks$future_extension$keep)
})

test_that("Apache Ossie round trips unknown fields and dialect variants", {
  catalog <- catalog_from_ossie(test_path("fixtures", "ossie-databricks.yaml"))
  exported <- catalog_to_ossie(catalog)
  document <- exported$document
  model <- document$semantic_model[[1]]
  date <- Filter(
    function(x) identical(x$name, "o_orderdate"),
    model$datasets[[1]]$fields
  )[[1]]

  expect_equal(document$future_document_field, "retained")
  expect_setequal(
    vapply(date$expression$dialects, `[[`, character(1), "dialect"),
    c("DATABRICKS", "ANSI_SQL")
  )
  expect_true(model$custom_extensions[[1]]$vendor_name == "DATABRICKS")
  expect_length(exported$diagnostics, 0)

  round_trip <- catalog_from_ossie(document)
  expect_equal(length(round_trip$models), 1)
  expect_equal(length(round_trip$definitions), 5)
})

test_that("Apache Ossie parses JSON without a Python dependency", {
  input <- yaml::read_yaml(test_path("fixtures", "ossie-databricks.yaml"))
  path <- withr::local_tempfile(fileext = ".json")
  jsonlite::write_json(input, path, auto_unbox = TRUE, pretty = TRUE)

  catalog <- catalog_from_ossie(path)

  expect_equal(catalog$models[[1]]$name, "sales")
  expect_equal(catalog$sources[[1]]$kind, "ossie")
})

test_that("Snowflake Ossie extensions retain native payloads", {
  document <- list(
    version = "0.2.0.dev0",
    semantic_model = list(list(
      name = "lending",
      datasets = list(list(
        name = "loans",
        source = "LENDING.PUBLIC.LOANS",
        fields = list(list(
          name = "loan_id",
          expression = list(dialects = list(list(
            dialect = "SNOWFLAKE",
            expression = "loan_id"
          )))
        ))
      )),
      custom_extensions = list(list(
        vendor_name = "SNOWFLAKE",
        data = '{"semantic_view":"LENDING.PUBLIC.LOAN_METRICS","verified_queries":["count_loans"]}'
      ))
    ))
  )

  catalog <- catalog_from_ossie(document)
  exported <- catalog_to_ossie(catalog)

  expect_equal(
    catalog$models[[1]]$extensions$snowflake$semantic_view,
    "LENDING.PUBLIC.LOAN_METRICS"
  )
  expect_equal(
    exported$document$semantic_model[[1]]$custom_extensions[[1]]$vendor_name,
    "SNOWFLAKE"
  )
})

test_that("Apache Ossie versions and relationship references fail closed", {
  expect_snapshot(
    catalog_from_ossie(list(version = "9.9", semantic_model = list())),
    error = TRUE
  )
  invalid <- list(
    version = "0.2.0.dev0",
    semantic_model = list(list(
      name = "bad",
      datasets = list(list(name = "orders", source = "db.schema.orders")),
      relationships = list(list(
        name = "missing",
        from = "orders",
        to = "customers",
        from_columns = "customer_id",
        to_columns = "id"
      ))
    ))
  )
  expect_snapshot(catalog_from_ossie(invalid), error = TRUE)
})

test_that("Apache Ossie export reports extension-only and omitted constructs", {
  catalog <- catalog_from_ossie(test_path("fixtures", "ossie-databricks.yaml"))
  source <- catalog$sources[[1]]
  term <- new_catalog_term(
    "term:revenue",
    source$id,
    "revenue",
    "Money earned."
  )
  calculation <- new_catalog_calculation(
    "calculation:verified",
    source$id,
    "verified",
    execution = new_catalog_execution("verified_sql", "databricks", "SELECT 1")
  )
  catalog$terms[[term$id]] <- term
  catalog$calculations[[calculation$id]] <- calculation
  definition <- catalog$definitions[[1]]
  definition$expressions <- list(new_catalog_expression(
    "private_dialect",
    "order_id"
  ))
  catalog$definitions[[definition$id]] <- definition
  evaluation <- new_catalog_context(
    "context:evaluation",
    source$id,
    "evaluation",
    "Expected answer",
    scope = catalog$models[[1]]$id,
    delivery = "evaluation"
  )
  catalog$context[[evaluation$id]] <- evaluation

  exported <- catalog_to_ossie(catalog)
  codes <- vapply(exported$diagnostics, `[[`, character(1), "code")

  expect_true("ossie_calculation_omitted" %in% codes)
  expect_true("ossie_term_omitted" %in% codes)
  expect_true("ossie_expression_extension_only" %in% codes)
  expect_true("ossie_context_omitted" %in% codes)
})

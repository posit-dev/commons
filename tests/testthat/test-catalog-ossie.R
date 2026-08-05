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

test_that("Apache Ossie models are public authored metadata", {
  document <- list(
    version = "0.1.1",
    semantic_model = list(list(
      name = "sales",
      datasets = list(list(
        name = "orders",
        source = "orders",
        description = "One row per order.",
        fields = list(list(
          name = "amount",
          expression = list(dialects = list(list(
            dialect = "ANSI_SQL",
            expression = "amount"
          )))
        ))
      )),
      metrics = list(list(
        name = "revenue",
        expression = list(dialects = list(list(
          dialect = "ANSI_SQL",
          expression = "SUM(amount)"
        )))
      ))
    ))
  )
  input <- withr::local_tempfile(fileext = ".yaml")
  yaml::write_yaml(document, input)
  model <- ossie_model(input)
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "orders", data.frame(amount = c(10, 20)))

  source <- data_source(
    con,
    dictionary = model,
    options = data_source_options(include = "orders")
  )

  expect_s3_class(source$dictionary, "commons_data_dictionary")
  expect_equal(source$dictionary$tables$orders$description, "One row per order.")
  expect_setequal(
    definitions_registry(list(warehouse = source))$defs$name,
    c("amount", "revenue")
  )
})

test_that("Apache Ossie dependencies are filtered with selected datasets", {
  authored <- ossie_model(test_path("fixtures", "ossie-databricks.yaml"))
  source <- new_catalog_source(
    "source:databricks",
    "databricks",
    identifier_case = "lower"
  )
  orders <- new_catalog_relation(
    "relation:orders",
    source$id,
    new_source_path(c(
      catalog = "samples",
      schema = "tpch",
      table = "orders"
    ))
  )
  discovered <- new_commons_catalog(
    sources = list(source),
    relations = list(orders)
  )

  merged <- catalog_merge(discovered, authored)
  definitions <- vapply(merged$definitions, `[[`, character(1), "name")
  kinds <- vapply(merged$context, `[[`, character(1), "kind")

  expect_equal(names(merged$relations), orders$id)
  expect_equal(merged$relations[[orders$id]]$constraints[[1]]$kind, "primary_key")
  expect_length(merged$relations[[orders$id]]$constraints, 1)
  expect_length(merged$models[[1]]$relationships, 0)
  expect_false("total_revenue" %in% definitions)
  expect_false("ossie_relationship_context" %in% kinds)
})

test_that("cross-dataset Ossie metrics remain interchange-only", {
  document <- list(
    version = "0.1.1",
    semantic_model = list(list(
      name = "sales",
      datasets = list(
        list(name = "orders", source = "db.public.orders"),
        list(name = "customers", source = "db.public.customers")
      ),
      metrics = list(list(
        name = "blended_value",
        expression = list(dialects = list(list(
          dialect = "ANSI_SQL",
          expression = "SUM(orders.amount) + SUM(customers.value)"
        )))
      ))
    ))
  )

  catalog <- catalog_from_ossie(document)
  definition <- catalog$definitions[[1]]

  expect_equal(definition$visibility, "private")
  expect_equal(nrow(catalog_definition_registry(catalog)$defs), 0)
  expect_equal(
    catalog$diagnostics[[1]]$code,
    "ossie_metric_not_callable"
  )
  expect_length(catalog_to_ossie(catalog)$document$semantic_model[[1]]$metrics, 1)
})

test_that("Apache Ossie models write to YAML and JSON", {
  model <- ossie_model(test_path("fixtures", "ossie-databricks.yaml"))
  yaml_path <- withr::local_tempfile(fileext = ".yaml")
  json_path <- withr::local_tempfile(fileext = ".json")

  expect_invisible(write_ossie(model, yaml_path))
  expect_invisible(write_ossie(model, json_path))
  expect_s3_class(ossie_model(yaml_path), "commons_catalog")
  expect_s3_class(ossie_model(json_path), "commons_catalog")
  expect_error(write_ossie(model, yaml_path), "already exists")
  expect_invisible(write_ossie(model, yaml_path, overwrite = TRUE))
})

test_that("Apache Ossie export version is selectable", {
  model <- ossie_model(test_path("fixtures", "ossie-databricks.yaml"))
  path <- withr::local_tempfile(fileext = ".yaml")

  expect_invisible(write_ossie(model, path, version = "0.1.1"))
  expect_equal(yaml::read_yaml(path)$version, "0.1.1")
  expect_snapshot(
    write_ossie(model, path, overwrite = TRUE, version = "9.9"),
    error = TRUE
  )
})

test_that("Snowflake Ossie extensions retain native payloads", {
  document <- list(
    version = "0.1.1",
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
          ))),
          dimension = list(is_time = FALSE)
        ), list(
          name = "balance",
          expression = list(dialects = list(list(
            dialect = "SNOWFLAKE",
            expression = "balance"
          )))
        ))
      )),
      custom_extensions = list(list(
        vendor = "SNOWFLAKE",
        content = paste0(
          '{"custom_instructions":"Use booked balances.",',
          '"verified_queries":[{"name":"count_loans",',
          '"question":"How many loans?","sql":"SELECT COUNT(*) FROM loans"}]}'
        )
      ))
    ))
  )

  catalog <- catalog_from_ossie(document)
  exported <- catalog_to_ossie(catalog)
  definitions <- catalog$definitions
  roles <- setNames(
    vapply(definitions, `[[`, character(1), "role"),
    vapply(definitions, `[[`, character(1), "name")
  )
  context <- vapply(catalog$context, `[[`, character(1), "text")
  extension <- exported$document$semantic_model[[1]]$custom_extensions[[1]]

  expect_equal(unname(roles[c("loan_id", "balance")]), c("dimension", "fact"))
  expect_true(any(grepl("Use booked balances", context, fixed = TRUE)))
  expect_true(any(grepl("How many loans", context, fixed = TRUE)))
  expect_equal(exported$document$version, "0.1.1")
  expect_equal(extension$vendor, "SNOWFLAKE")
  expect_equal(
    jsonlite::fromJSON(extension$content)$custom_instructions,
    "Use booked balances."
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
  catalog$models[[1]]$extensions$genie <- list(rule = "Use fiscal years.")
  catalog$relations[[1]]$synonyms <- "purchases"
  catalog$relations[[1]]$constraints[[1]]$enforcement <- "asserted"

  exported <- catalog_to_ossie(catalog)
  codes <- vapply(exported$diagnostics, `[[`, character(1), "code")

  expect_true("ossie_calculation_omitted" %in% codes)
  expect_true("ossie_term_omitted" %in% codes)
  expect_true("ossie_expression_extension_only" %in% codes)
  expect_true("ossie_context_omitted" %in% codes)
  expect_true("ossie_extension_only" %in% codes)
  expect_true("ossie_constraints_extension_only" %in% codes)
  vendors <- ossie_extension_vendors(
    exported$document$semantic_model[[1]]$custom_extensions
  )
  expect_true("genie" %in% vendors)
  dataset <- exported$document$semantic_model[[1]]$datasets[[1]]
  expect_true("purchases" %in% ossie_ai_synonyms(dataset$ai_context))
})

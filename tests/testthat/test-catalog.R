test_that("data dictionaries round-trip through commons catalogs", {
  dictionary <- new_data_dictionary(list(
    name = "Sales",
    description = "Commercial data.",
    details = "Revenue excludes tax.",
    tables = list(list(
      name = "orders",
      label = "Orders",
      description = "One row per order.",
      columns = list(
        list(name = "id", type = "integer", description = "Order ID."),
        list(
          name = "amount",
          type = "number",
          units = "USD",
          examples = c(10, 20),
          constraints = "non-negative"
        )
      ),
      definitions = list(list(
        name = "revenue",
        expr = "SUM(amount)",
        type = "number",
        description = "Gross revenue."
      ))
    )),
    relationships = list(list(
      join = "orders.customer_id = customers.id",
      cardinality = "many-to-one"
    )),
    glossary = list(revenue = "Money earned before refunds.")
  ))

  catalog <- catalog_from_data_dictionary(dictionary)

  expect_s3_class(catalog, "commons_catalog")
  expect_length(catalog$sources, 1)
  expect_length(catalog$relations, 1)
  expect_length(catalog$models, 1)
  expect_length(catalog$definitions, 1)
  expect_length(catalog$terms, 1)
  expect_identical(catalog_to_data_dictionary(catalog), dictionary)
})

test_that("data dictionary catalogs project to existing runtime surfaces", {
  dictionary <- new_data_dictionary(list(
    details = "Use booked revenue.",
    tables = list(orders = list(
      description = "One row per order.",
      columns = list(amount = list(type = "number")),
      definitions = list(revenue = list(
        expr = "SUM(amount)",
        type = "number"
      ))
    )),
    glossary = list(booked = "An order with a signed contract.")
  ))
  catalog <- catalog_from_data_dictionary(dictionary)

  registry <- catalog_definition_registry(catalog, "warehouse")
  expect_equal(registry$defs$name, "revenue")
  expect_equal(registry$defs$table, "orders")
  expect_equal(registry$defs$source, "warehouse")
  expect_equal(registry$defs$role, "metric")
  expect_equal(registry$defs$expanded, "SUM(amount)")

  expect_setequal(
    catalog_context_chunks(catalog),
    c(
      "Use booked revenue.",
      "Table `orders`: One row per order.",
      "booked: An order with a signed contract."
    )
  )
  expect_length(catalog_calculation_registry(catalog), 0)
})

test_that("catalog constructors retain structured identity and access", {
  path <- new_source_path(DBI::Id(
    catalog = "ANALYTICS",
    schema = "PUBLIC",
    table = "ORDERS"
  ))
  source <- new_catalog_source(
    "source:snowflake",
    "snowflake",
    identifier_case = "upper"
  )
  relation <- new_catalog_relation(
    "relation:orders",
    source$id,
    path,
    access = new_catalog_access("visible_only", "REFERENCES")
  )
  catalog <- new_commons_catalog(sources = list(source), relations = list(relation))

  expect_identical(relation$path$roles, c("catalog", "schema", "table"))
  expect_identical(
    relation$path$components,
    c("ANALYTICS", "PUBLIC", "ORDERS")
  )
  expect_equal(relation$access$state, "visible_only")
  expect_silent(validate_commons_catalog(catalog))
})

test_that("catalog validation rejects dangling references", {
  source <- new_catalog_source("source:test", "test")
  relation <- new_catalog_relation(
    "relation:test",
    "source:missing",
    new_source_path(c(table = "test"))
  )

  expect_snapshot(
    new_commons_catalog(sources = list(source), relations = list(relation)),
    error = TRUE
  )
})

test_that("dictionary projection rejects ambiguous table names", {
  source <- new_catalog_source("source:test", "test")
  relations <- list(
    new_catalog_relation(
      "relation:a",
      source$id,
      new_source_path(c(schema = "a", table = "orders")),
      name = "orders"
    ),
    new_catalog_relation(
      "relation:b",
      source$id,
      new_source_path(c(schema = "b", table = "orders")),
      name = "orders"
    )
  )
  catalog <- new_commons_catalog(sources = list(source), relations = relations)

  expect_snapshot(catalog_to_data_dictionary(catalog), error = TRUE)
})

test_that("data sources carry the dictionary catalog", {
  source <- data_source(
    sales = data.frame(revenue = 1),
    dictionary = local_definitions_dict(
      definitions = c(
        "      - name: total_revenue",
        "        expr: SUM(revenue)",
        "        type: number"
      )
    )
  )

  expect_s3_class(source$catalog, "commons_catalog")
  expect_equal(
    catalog_definition_registry(source$catalog)$defs$name,
    "total_revenue"
  )
})

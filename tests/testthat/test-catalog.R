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

test_that("authored metadata merges onto qualified discovered relations", {
  discovered_provenance <- new_catalog_provenance(
    "discovered",
    "source:warehouse"
  )
  source <- new_catalog_source(
    "source:warehouse",
    "snowflake",
    identifier_case = "upper",
    provenance = discovered_provenance
  )
  relation <- new_catalog_relation(
    "relation:orders",
    source$id,
    new_source_path(c(
      catalog = "ANALYTICS",
      schema = "PUBLIC",
      table = "ORDERS"
    )),
    description = "Warehouse description.",
    tags = "certified",
    columns = list(new_catalog_column(
      "AMOUNT",
      native_type = "NUMBER",
      description = "Warehouse column description.",
      provenance = discovered_provenance
    )),
    access = new_catalog_access("queryable"),
    provenance = discovered_provenance
  )
  discovered <- new_commons_catalog(
    sources = list(source),
    relations = list(relation)
  )
  authored <- catalog_from_data_dictionary(new_data_dictionary(list(
    tables = list(orders = list(
      description = "Authored description.",
      columns = list(amount = list(
        type = "number",
        description = "Authored column description."
      ))
    ))
  )))

  merged <- catalog_merge(discovered, authored)
  orders <- merged$relations[["relation:orders"]]

  expect_equal(orders$description, "Authored description.")
  expect_equal(orders$access$state, "queryable")
  expect_setequal(orders$tags, "certified")
  expect_equal(orders$columns$AMOUNT$native_type, "NUMBER")
  expect_equal(
    orders$columns$AMOUNT$description,
    "Authored column description."
  )
  expect_equal(merged$models[[1]]$datasets, "relation:orders")
  expect_equal(merged$context[[1]]$scope, "relation:orders")
})

test_that("relative authored relation matches must be unambiguous", {
  source <- new_catalog_source(
    "source:warehouse",
    "snowflake",
    identifier_case = "upper"
  )
  relations <- lapply(c("PUBLIC", "STAGING"), function(schema) {
    new_catalog_relation(
      paste0("relation:", schema),
      source$id,
      new_source_path(c(
        catalog = "ANALYTICS",
        schema = schema,
        table = "ORDERS"
      ))
    )
  })
  discovered <- new_commons_catalog(
    sources = list(source),
    relations = relations
  )
  authored <- catalog_from_data_dictionary(new_data_dictionary(list(
    tables = list(orders = list(description = "Orders."))
  )))

  expect_snapshot(catalog_merge(discovered, authored), error = TRUE)
})

test_that("constraint enforcement is distinct from constraint kind", {
  constraint <- new_catalog_constraint(
    "foreign_key",
    "customer_id",
    reference = list(table = "customers", columns = "id"),
    enforcement = "asserted",
    native = list(rely = TRUE)
  )
  source <- new_catalog_source("source:test", "test")
  relation <- new_catalog_relation(
    "relation:test",
    source$id,
    new_source_path(c(table = "orders")),
    constraints = list(constraint)
  )

  expect_equal(relation$constraints[[1]]$kind, "foreign_key")
  expect_equal(relation$constraints[[1]]$enforcement, "asserted")
})

test_that("calculations require typed adapter-owned bindings", {
  arguments <- list(
    month = new_catalog_argument("date"),
    region = new_catalog_argument(
      "string",
      binding = "identifier",
      choices = c("east", "west")
    )
  )
  execution <- new_catalog_execution(
    "parameterized_sql",
    "snowflake",
    "SELECT * FROM identifier(?) WHERE month = ?",
    list(
      new_catalog_binding("month"),
      new_catalog_binding("region", "identifier")
    )
  )
  calculation <- new_catalog_calculation(
    "calculation:revenue",
    "source:test",
    "revenue",
    arguments = arguments,
    execution = execution
  )

  expect_equal(calculation$arguments$month$type, "date")
  expect_snapshot(
    new_catalog_calculation(
      "calculation:bad",
      "source:test",
      "bad",
      arguments = arguments,
      execution = new_catalog_execution(
        "parameterized_sql",
        "snowflake",
        "SELECT 1",
        list(new_catalog_binding("month"))
      )
    ),
    error = TRUE
  )
  expect_snapshot(
    new_catalog_argument("string", binding = "identifier"),
    error = TRUE
  )
})

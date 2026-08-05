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
      new_catalog_binding("region", "identifier", "{{region}}")
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

test_that("namespace selection takes precedence over duplicate exact selection", {
  exact <- catalog_selection_id(DBI::Id(schema = "main", table = "orders"), "exact")
  namespace <- catalog_selection_id(
    catalog_tag_id(DBI::Id(schema = "main", table = "orders"), "table"),
    "namespace"
  )

  selected <- catalog_collapse_selected_ids(
    list(exact, namespace),
    rep(catalog_source_path_key(exact), 2)
  )

  expect_length(selected, 1)
  expect_equal(attr(selected[[1]], "commons_selection"), "namespace")
  expect_equal(attr(selected[[1]], "commons_kind"), "table")
})

test_that("associated semantic definitions respect physical dependency closure", {
  catalog_source <- new_catalog_source("source:test", "snowflake")
  orders <- new_catalog_relation(
    "relation:orders",
    catalog_source$id,
    new_source_path(c("DB", "PUBLIC", "ORDERS"), c("catalog", "schema", "table"))
  )
  customers <- new_catalog_relation(
    "relation:customers",
    catalog_source$id,
    new_source_path(c("DB", "PUBLIC", "CUSTOMERS"), c("catalog", "schema", "table"))
  )
  semantic <- new_catalog_relation(
    "relation:model",
    catalog_source$id,
    new_source_path(c("DB", "PUBLIC", "SALES"), c("catalog", "schema", "table")),
    kind = "semantic_view"
  )
  model <- new_catalog_model(
    "model:sales",
    catalog_source$id,
    "SALES",
    datasets = c(orders$id, customers$id),
    execution = list(kind = "snowflake_semantic_view"),
    exposed = semantic$id,
    dependencies = c(orders$id, customers$id)
  )
  kept <- new_catalog_definition(
    "definition:orders",
    model$id,
    semantic$id,
    "metric",
    "ORDER_COUNT",
    expressions = list(new_catalog_expression("snowflake", "COUNT(*)")),
    dependencies = orders$id
  )
  skipped <- new_catalog_definition(
    "definition:customers",
    model$id,
    semantic$id,
    "metric",
    "CUSTOMER_COUNT",
    expressions = list(new_catalog_expression("snowflake", "COUNT(*)")),
    dependencies = customers$id
  )
  calculation <- new_catalog_calculation(
    "calculation:sales",
    catalog_source$id,
    "sales_query",
    dependencies = model$id,
    execution = new_catalog_execution("verified_sql", "snowflake", "SELECT 1")
  )
  provider <- new.env(parent = emptyenv())
  provider$selection_modes <- c("relation:orders" = "exact")
  provider$catalog <- new_commons_catalog(
    sources = list(catalog_source),
    relations = list(orders, customers, semantic),
    models = list(model),
    definitions = list(kept, skipped),
    calculations = list(calculation)
  )

  catalog_filter_associated_model(provider, semantic$id)

  expect_equal(names(provider$catalog$definitions), kept$id)
  expect_length(provider$catalog$calculations, 0)
  expect_length(provider$catalog$models, 1)
  expect_equal(provider$catalog$diagnostics[[1]]$code, "semantic_dependency_out_of_scope")
  registry <- definitions_registry(list(warehouse = list(
    catalog = provider$catalog,
    tables = "DB.PUBLIC.ORDERS",
    relation_labels = c("relation:orders" = "DB.PUBLIC.ORDERS")
  )))
  expect_equal(registry$defs$name, "ORDER_COUNT")
})

test_that("private and visible-only semantic definitions stay out of the registry", {
  source <- new_catalog_source("source:test", "snowflake")
  relation <- new_catalog_relation(
    "relation:model",
    source$id,
    new_source_path(c(table = "MODEL"))
  )
  model <- new_catalog_model(
    "model:test",
    source$id,
    "MODEL",
    datasets = relation$id,
    execution = list(kind = "snowflake_semantic_view"),
    access = new_catalog_access("visible_only")
  )
  definition <- new_catalog_definition(
    "definition:test",
    model$id,
    relation$id,
    "metric",
    "REVENUE",
    expressions = list(new_catalog_expression("snowflake", "SUM(REVENUE)"))
  )
  catalog <- new_commons_catalog(
    sources = list(source),
    relations = list(relation),
    models = list(model),
    definitions = list(definition)
  )

  expect_equal(nrow(catalog_definition_registry(catalog)$defs), 0)
  catalog$models[[model$id]]$access <- new_catalog_access("queryable")
  catalog$definitions[[definition$id]]$visibility <- "private"
  expect_equal(nrow(catalog_definition_registry(catalog)$defs), 0)
})

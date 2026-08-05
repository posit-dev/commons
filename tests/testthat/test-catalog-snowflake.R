test_that("Snowflake semantic YAML imports governed assets", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  source <- new_catalog_source(
    "source:snowflake",
    "snowflake",
    dialect = "snowflake",
    identifier_case = "upper"
  )
  relation <- new_catalog_relation(
    "relation:sales_model",
    source$id,
    new_source_path(
      c("ANALYTICS", "PUBLIC", "SALES_MODEL"),
      c("catalog", "schema", "table")
    ),
    kind = "semantic_view"
  )
  provider <- new.env(parent = emptyenv())
  provider$con <- con
  provider$catalog <- new_commons_catalog(
    sources = list(source),
    relations = list(relation)
  )
  provider$relation_labels <- c(
    "relation:sales_model" = "ANALYTICS.PUBLIC.SALES_MODEL"
  )
  specification <- yaml::yaml.load(paste(
    "name: SALES_MODEL",
    "description: Governed sales metrics.",
    "tables:",
    "  - name: ORDERS",
    "    description: One row per order.",
    "    base_table:",
    "      database: RAW",
    "      schema: PUBLIC",
    "      table: ORDERS",
    "    primary_key:",
    "      columns: [ORDER_ID]",
    "    dimensions:",
    "      - name: REGION",
    "        expr: REGION",
    "        data_type: VARCHAR",
    "    metrics:",
    "      - name: REVENUE",
    "        description: Booked revenue.",
    "        expr: SUM(AMOUNT)",
    "        access_modifier: public_access",
    "      - name: PRIVATE_MARGIN",
    "        expr: SUM(MARGIN)",
    "        access_modifier: private_access",
    "module_custom_instructions:",
    "  sql_generation: Use fiscal years.",
    "verified_queries:",
    "  - name: revenue_by_region",
    "    question: What is revenue by region?",
    "    sql: SELECT REGION, AGG(REVENUE) FROM SALES_MODEL GROUP BY REGION",
    sep = "\n"
  ))

  snowflake_import_semantic_model(provider, relation, specification)
  catalog <- provider$catalog
  registry <- catalog_definition_registry(
    catalog,
    table_labels = provider$relation_labels
  )

  expect_length(catalog$models, 1)
  expect_length(catalog$calculations, 1)
  expect_length(catalog$context, 2)
  expect_setequal(registry$defs$name, c("REGION", "REVENUE"))
  expect_false("PRIVATE_MARGIN" %in% registry$defs$name)
  dependency <- catalog$relations[[catalog$models[[1]]$datasets]]
  expect_equal(dependency$constraints[[1]]$enforcement, "asserted")
})

test_that("Snowflake metrics compile through SEMANTIC_VIEW", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  path <- new_source_path(
    c("ANALYTICS", "PUBLIC", "SALES_MODEL"),
    c("catalog", "schema", "table")
  )
  provider <- new.env(parent = emptyenv())
  provider$catalog <- new_commons_catalog()
  provider$catalog$models[["model:sales"]] <- new_catalog_model(
    "model:sales",
    "source:test",
    "SALES_MODEL",
    execution = list(kind = "snowflake_semantic_view", object = path)
  )
  source <- list(con = con, provider = provider)
  defs <- data.frame(
    name = c("REVENUE", "REGION"),
    role = c("metric", "dimension"),
    native_parent = c("ORDERS", "ORDERS"),
    stringsAsFactors = FALSE
  )

  sql <- snowflake_metric_sql(
    source,
    "model:sales",
    defs[1, , drop = FALSE],
    defs,
    dimensions = "REGION",
    filters = NULL,
    where = NULL
  )

  expect_match(sql, "SEMANTIC_VIEW", fixed = TRUE)
  expect_match(sql, "DIMENSIONS", fixed = TRUE)
  expect_match(sql, "METRICS", fixed = TRUE)
  expect_match(sql, "ORDERS.REVENUE", fixed = TRUE)
})

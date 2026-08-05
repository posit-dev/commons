test_that("Snowflake reports a missing current namespace", {
  local_mocked_bindings(
    dbGetQuery = function(...) {
      data.frame(
        principal = "USER",
        role = "ROLE",
        database_name = NA_character_,
        schema_name = NA_character_,
        account_name = "ACCOUNT",
        warehouse_name = "WAREHOUSE"
      )
    },
    .package = "DBI"
  )

  expect_snapshot(
    snowflake_default_objects(NULL, rlang::current_env()),
    error = TRUE
  )
})

test_that("Snowflake requires an active warehouse", {
  local_mocked_bindings(
    dbGetQuery = function(...) {
      data.frame(
        principal = "USER",
        role = "ROLE",
        database_name = "DATABASE",
        schema_name = "SCHEMA",
        account_name = "ACCOUNT",
        warehouse_name = NA_character_
      )
    },
    .package = "DBI"
  )

  expect_snapshot(
    snowflake_connection_snapshot(NULL, rlang::current_env()),
    error = TRUE
  )
})

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
  expect_length(catalog$context, 5)
  expect_setequal(registry$defs$name, c("REGION", "REVENUE"))
  expect_false("PRIVATE_MARGIN" %in% registry$defs$name)
  dependency <- catalog$relations[[catalog$models[[1]]$datasets]]
  expect_equal(dependency$constraints[[1]]$enforcement, "asserted")
})

test_that("Snowflake imports all three recorded semantic-view shapes", {
  recordings <- yaml::read_yaml(test_path(
    "fixtures",
    "snowflake-semantic-recordings.yaml"
  ))$recordings

  for (recording in recordings) {
    provider <- snowflake_test_provider(recording$semantic_view$name)
    relation <- provider$catalog$relations[[1]]
    snowflake_import_semantic_model(
      provider,
      relation,
      recording$semantic_view
    )

    expect_equal(
      length(provider$catalog$models[[1]]$datasets),
      recording$recorded_shape$tables
    )
    expect_true(length(provider$catalog$definitions) > 0)
    expect_silent(validate_commons_catalog(provider$catalog))
  }
})

test_that("Snowflake calls only read-only verified queries", {
  provider <- snowflake_test_provider("VERIFIED_MODEL")
  relation <- provider$catalog$relations[[1]]
  specification <- list(
    name = "VERIFIED_MODEL",
    tables = list(list(
      name = "ORDERS",
      base_table = list(database = "DB", schema = "PUBLIC", table = "ORDERS")
    )),
    verified_queries = list(
      list(name = "order_count", question = "How many orders?", sql = "SELECT COUNT(*) FROM ORDERS"),
      list(name = "unsafe_example", question = "Refresh the table", sql = "CALL REFRESH_ORDERS()")
    )
  )

  snowflake_import_semantic_model(provider, relation, specification)

  expect_equal(
    unname(vapply(provider$catalog$calculations, `[[`, character(1), "name")),
    "order_count"
  )
  contexts <- vapply(provider$catalog$context, `[[`, character(1), "text")
  expect_true(any(grepl("Refresh the table", contexts, fixed = TRUE)))
})

test_that("live Snowflake semantic discovery is opt in", {
  skip_if_not(identical(Sys.getenv("COMMONS_LIVE_SNOWFLAKE"), "true"))
  required <- c(
    "COMMONS_SNOWFLAKE_DATABASE",
    "COMMONS_SNOWFLAKE_SCHEMA",
    "COMMONS_SNOWFLAKE_TABLE"
  )
  skip_if(any(!nzchar(Sys.getenv(required))))
  con <- DBI::dbConnect(odbc::snowflake())
  withr::defer(DBI::dbDisconnect(con))
  source <- data_source(
    con,
    options = data_source_options(include = DBI::Id(
      catalog = Sys.getenv("COMMONS_SNOWFLAKE_DATABASE"),
      schema = Sys.getenv("COMMONS_SNOWFLAKE_SCHEMA"),
      table = Sys.getenv("COMMONS_SNOWFLAKE_TABLE")
    ))
  )

  expect_true(length(source$provider$catalog$relations) > 0)
  expect_equal(nrow(source_describe(source, list_tables(source))$sample), 0)
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

test_that("Snowflake native queries accept time dimensions and facts", {
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
    name = c("REVENUE", "ORDER_DATE", "ORDER_TOTAL"),
    role = c("metric", "time_dimension", "fact"),
    native_parent = rep("ORDERS", 3),
    stringsAsFactors = FALSE
  )

  sql <- snowflake_metric_sql(
    source,
    "model:sales",
    defs[1, , drop = FALSE],
    defs,
    dimensions = "ORDER_DATE",
    filters = NULL,
    where = list(list(column = "ORDER_TOTAL", op = ">", value = "10"))
  )

  expect_match(sql, "ORDERS.ORDER_DATE", fixed = TRUE)
  expect_match(sql, "ORDERS.ORDER_TOTAL", fixed = TRUE)
})

test_that("Snowflake masking metadata marks restricted columns", {
  row <- data.frame(
    check.names = FALSE,
    "policy name" = "MASK_EMAIL",
    "privacy domain" = NA_character_
  )

  expect_equal(snowflake_column_restrictions(row), "policy name")
})

test_that("Snowflake semantic-view variables are typed and quoted", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  variables <- list(
    list(name = "threshold", data_type = "NUMBER(10,2)"),
    list(name = "region", data_type = "VARCHAR", default_value = "all")
  )

  clause <- snowflake_variable_clause(
    variables,
    '{"threshold":100.5,"region":"EMEA\' OR 1=1 --"}',
    con
  )

  expect_match(clause, "threshold => 100.5", fixed = TRUE)
  expect_match(clause, "'EMEA'' OR 1=1 --'", fixed = TRUE)
  expect_snapshot(
    snowflake_variable_clause(variables, "{}", con),
    error = TRUE
  )
  expect_snapshot(
    snowflake_variable_clause(
      variables,
      '{"threshold":"not numeric"}',
      con
    ),
    error = TRUE
  )
})

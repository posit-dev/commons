test_that("Databricks metric-view YAML imports governed assets", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  source <- new_catalog_source(
    "source:databricks",
    "databricks",
    dialect = "databricks"
  )
  relation <- new_catalog_relation(
    "relation:sales_metrics",
    source$id,
    new_source_path(
      c("main", "analytics", "sales_metrics"),
      c("catalog", "schema", "table")
    ),
    kind = "metric_view"
  )
  provider <- new.env(parent = emptyenv())
  provider$con <- con
  provider$catalog <- new_commons_catalog(
    sources = list(source),
    relations = list(relation)
  )
  specification <- yaml::yaml.load(paste(
    "version: 1.1",
    "comment: Governed sales metrics.",
    "source: samples.tpch.orders",
    "parameters:",
    "  - name: minimum_amount",
    "    data_type: double",
    "    default: 0",
    "filter: o_totalprice > minimum_amount",
    "joins:",
    "  - name: customer",
    "    source: samples.tpch.customer",
    "    on: source.o_custkey = customer.c_custkey",
    "    rely:",
    "      at_most_one_match: true",
    "fields:",
    "  - name: region",
    "    expr: customer.c_mktsegment",
    "    comment: Customer segment.",
    "measures:",
    "  - name: revenue",
    "    expr: SUM(o_totalprice)",
    "    display_name: Total Revenue",
    "    synonyms: [sales]",
    "    window:",
    "      - order: region",
    "        range: cumulative",
    sep = "\n"
  ))

  databricks_import_metric_model(provider, relation, specification)
  catalog <- provider$catalog
  registry <- catalog_definition_registry(
    catalog,
    table_labels = c(
      "relation:sales_metrics" = "main.analytics.sales_metrics"
    )
  )

  expect_length(catalog$models, 1)
  expect_length(catalog$models[[1]]$datasets, 2)
  expect_setequal(registry$defs$name, c("region", "revenue"))
  expect_equal(unique(registry$defs$execution), "databricks_metric_view")
  expect_equal(catalog$models[[1]]$version, "1.1")
  expect_true(length(catalog$models[[1]]$execution$parameters) == 1)
  expect_true(length(catalog$context) >= 2)
  root <- catalog$relations[[catalog$models[[1]]$datasets[[1]]]]
  expect_equal(root$constraints[[1]]$enforcement, "asserted")
})

test_that("Databricks measures compile through MEASURE", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  path <- new_source_path(
    c("main", "analytics", "sales_metrics"),
    c("catalog", "schema", "table")
  )
  provider <- new.env(parent = emptyenv())
  provider$catalog <- new_commons_catalog()
  provider$catalog$models[["model:sales"]] <- new_catalog_model(
    "model:sales",
    "source:test",
    "sales_metrics",
    execution = list(kind = "databricks_metric_view", object = path)
  )
  source <- list(con = con, provider = provider)
  defs <- data.frame(
    name = c("revenue", "region"),
    role = c("metric", "dimension"),
    stringsAsFactors = FALSE
  )

  sql <- databricks_metric_sql(
    source,
    "model:sales",
    defs[1, , drop = FALSE],
    defs,
    dimensions = "region",
    filters = NULL,
    where = NULL
  )

  expect_match(sql, "MEASURE(revenue) AS revenue", fixed = TRUE)
  expect_match(sql, "main.analytics.sales_metrics", fixed = TRUE)
  expect_match(sql, "GROUP BY region", fixed = TRUE)
})

test_that("Databricks metric-view parameters are typed and quoted", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  object <- DBI::Id(catalog = "main", schema = "default", table = "metrics")
  parameters <- list(
    list(name = "discount", data_type = "double"),
    list(name = "region", data_type = "string", default = "all")
  )

  sql <- databricks_metric_source(
    object,
    parameters,
    '{"discount":0.15,"region":"EMEA\' OR 1=1 --"}',
    con
  )

  expect_match(sql, "discount => 0.15", fixed = TRUE)
  expect_match(sql, "'EMEA'' OR 1=1 --'", fixed = TRUE)
  expect_snapshot(
    databricks_metric_source(object, parameters, "{}", con),
    error = TRUE
  )
  expect_snapshot(
    databricks_metric_source(
      object,
      parameters,
      '{"discount":"not a number"}',
      con
    ),
    error = TRUE
  )
})

test_that("Databricks metric-view versions fail closed", {
  expect_false(databricks_metric_version_supported("9.9"))
  expect_true(databricks_metric_version_supported("1.1"))
})

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
  specification <- yaml::read_yaml(test_path(
    "fixtures",
    "databricks-metric-view.yaml"
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

test_that("namespace metric views hydrate their semantics lazily", {
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
  provider$relation_labels <- c(
    "relation:sales_metrics" = "main.analytics.sales_metrics"
  )
  provider$selection_modes <- c("relation:sales_metrics" = "namespace")
  reads <- 0L
  local_mocked_bindings(
    databricks_read_metric_yaml = function(con, path) {
      reads <<- reads + 1L
      yaml::read_yaml(test_path("fixtures", "databricks-metric-view.yaml"))
    }
  )

  databricks_import_semantics(provider)
  expect_equal(reads, 0L)
  expect_length(provider$catalog$models, 0)

  databricks_import_semantic_relation(provider, relation$id)
  expect_equal(reads, 1L)
  expect_length(provider$catalog$models, 1)
  expect_true(length(provider$catalog$definitions) > 0)
})

test_that("live Databricks catalog discovery is opt in", {
  skip_if_not(identical(Sys.getenv("COMMONS_LIVE_DATABRICKS"), "true"))
  required <- c(
    "COMMONS_DATABRICKS_CATALOG",
    "COMMONS_DATABRICKS_SCHEMA",
    "COMMONS_DATABRICKS_TABLE"
  )
  skip_if(any(!nzchar(Sys.getenv(required))))
  con <- DBI::dbConnect(odbc::odbc(), "Databricks")
  withr::defer(DBI::dbDisconnect(con))
  source <- data_source(
    con,
    options = data_source_options(include = DBI::Id(
      catalog = Sys.getenv("COMMONS_DATABRICKS_CATALOG"),
      schema = Sys.getenv("COMMONS_DATABRICKS_SCHEMA"),
      table = Sys.getenv("COMMONS_DATABRICKS_TABLE")
    ))
  )

  expect_true(length(source$provider$catalog$relations) > 0)
  expect_equal(nrow(source_describe(source, list_tables(source))$sample), 0)
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

test_that("Databricks JSON metadata preserves types and column masks", {
  metadata <- list(
    columns = list(list(
      name = "email",
      type = list(name = "varchar", length = 255),
      nullable = TRUE
    )),
    column_masks = list(list(
      column_name = "email",
      mask_function = list(function_name = "mask_email")
    ))
  )

  expect_equal(databricks_type_text(metadata$columns[[1]]$type), "varchar(255)")
  expect_equal(
    databricks_column_restrictions(metadata, "email"),
    "column_mask"
  )
  expect_length(databricks_column_restrictions(metadata, "customer_id"), 0)
})

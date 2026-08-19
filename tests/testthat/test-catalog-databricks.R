test_that("Databricks information schema retains native relation metadata", {
  rows <- data.frame(
    table_catalog = c("Data.Catalog", "main"),
    table_schema = c("Odd Schema", "default"),
    table_name = c("Sales.Report", "orders"),
    table_type = c("VIEW", "MANAGED"),
    comment = c("A useful view", ""),
    stringsAsFactors = FALSE
  )

  relations <- databricks_relations_from_information_schema(rows)

  expect_length(relations, 2)
  expect_equal(relations[[1]]$kind, "view")
  expect_equal(relations[[1]]$description, "A useful view")
  expect_equal(relations[[2]]$kind, "table")
  expect_null(relations[[2]]$description)
  expect_identical(
    relations[[1]]$id,
    DBI::Id(
      catalog = "Data.Catalog",
      schema = "Odd Schema",
      table = "Sales.Report"
    )
  )

  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(
    as.character(DBI::dbQuoteIdentifier(con, relations[[1]]$id)),
    '"Data.Catalog"."Odd Schema"."Sales.Report"'
  )
})

test_that("Databricks ODBC metadata identifies metric views", {
  rows <- data.frame(
    table_catalog = rep("main", 3),
    table_schema = rep("analytics", 3),
    table_name = c("orders", "summary", "sales_metrics"),
    table_type = c("MANAGED", "VIEW", "VIEW"),
    comment = c("", "", "Governed sales metrics."),
    stringsAsFactors = FALSE
  )
  object_types <- stats::setNames(
    c("table", "view", "metric view"),
    databricks_object_key(
      "analytics",
      c("orders", "summary", "sales_metrics")
    )
  )

  relations <- databricks_relations_from_information_schema(
    rows,
    object_types
  )

  expect_equal(
    vapply(relations, `[[`, character(1), "kind"),
    c("table", "view", "metric_view")
  )
  expect_equal(relations[[3]]$description, "Governed sales metrics.")
})

test_that("Databricks metric YAML imports explicit fields and measures", {
  specification <- list(
    version = 1.1,
    comment = "Governed sales metrics.",
    fields = list(
      list(expr = "source.*"),
      list(
        name = "region",
        expr = "customer_region",
        comment = "Customer region.",
        display_name = "Sales Region",
        synonyms = c("territory", "market")
      )
    ),
    measures = list(
      list(
        name = "order_count",
        expr = "COUNT(*)",
        comment = "Number of orders."
      )
    )
  )
  id <- DBI::Id(
    catalog = "main",
    schema = "analytics",
    table = "sales_metrics"
  )

  model <- databricks_semantic_model_from_spec(id, specification)

  expect_s3_class(model, "commons_semantic_model")
  expect_equal(model$backend, "databricks_metric_view")
  expect_equal(model$description, "Governed sales metrics.")
  expect_equal(
    vapply(model$dimensions, `[[`, character(1), "name"),
    "region"
  )
  expect_equal(model$dimensions[[1]]$label, "Sales Region")
  expect_equal(model$dimensions[[1]]$synonyms, c("territory", "market"))
  expect_equal(
    vapply(model$metrics, `[[`, character(1), "name"),
    "order_count"
  )
})

test_that("Databricks metric SQL uses MEASURE and model fields", {
  model <- databricks_semantic_model_from_spec(
    DBI::Id(
      catalog = "main",
      schema = "analytics",
      table = "sales_metrics"
    ),
    list(
      version = 1.1,
      fields = list(list(name = "region", expr = "region")),
      measures = list(list(name = "revenue", expr = "SUM(revenue)"))
    )
  )
  source <- test_source()
  label <- table_id_label(model$id)
  source$semantic_models <- stats::setNames(list(model), label)
  members <- registry_semantic_members(
    semantic_models_registry(list(databricks = source))
  )
  metrics <- members[members$kind == "metric", , drop = FALSE]
  dimensions <- members[members$kind == "dimension", , drop = FALSE]

  sql <- databricks_semantic_metric_sql(
    model,
    metrics,
    dimensions,
    where = list(list(column = "region", op = "=", value = "EMEA")),
    members = members,
    con = DBI::ANSI()
  )

  expect_equal(
    sql,
    paste(
      "SELECT \"region\", MEASURE(\"revenue\") AS \"revenue\"",
      "FROM \"main\".\"analytics\".\"sales_metrics\"",
      "WHERE (\"region\" = 'EMEA')",
      "GROUP BY \"region\""
    )
  )
})

test_that("call_metrics dispatches through Databricks metric views", {
  model <- databricks_semantic_model_from_spec(
    DBI::Id(
      catalog = "main",
      schema = "analytics",
      table = "sales_metrics"
    ),
    list(
      version = 1.1,
      fields = list(list(name = "region", expr = "region")),
      measures = list(list(name = "revenue", expr = "SUM(revenue)"))
    )
  )
  source <- test_source()
  source$semantic_models[[table_id_label(model$id)]] <- model
  sources <- list(databricks = source)
  registry <- semantic_models_registry(sources)
  query <- NULL
  local_mocked_bindings(
    source_query = function(source, sql) {
      query <<- sql
      data.frame(revenue = 42)
    }
  )

  result <- call_metrics_impl(
    empty_definitions(),
    sources,
    new_handle_store(),
    metrics = "revenue",
    dimensions = "region",
    semantic_models = registry
  )

  expect_match(query, "MEASURE(revenue)", fixed = TRUE)
  expect_match(query, "GROUP BY region", fixed = TRUE)
  expect_equal(result@extra$commons_tag, "A")
})

test_that("Databricks view definitions are read in driver-sized chunks", {
  queries <- character()
  local_mocked_bindings(
    dbGetQuery = function(con, sql) {
      queries <<- c(queries, sql)
      if (grepl("length(view_definition)", sql, fixed = TRUE)) {
        return(data.frame(definition_length = 1000L))
      }
      data.frame(chunk_1 = "version: 1.1\n", chunk_2 = "measures: []\n")
    },
    .package = "DBI"
  )

  definition <- databricks_view_definition(
    DBI::ANSI(),
    DBI::Id(catalog = "main", schema = "analytics", table = "metrics")
  )

  expect_equal(definition, "version: 1.1\nmeasures: []\n")
  expect_match(queries[[2]], "substring(view_definition, 1, 900)", fixed = TRUE)
  expect_match(queries[[2]], "substring(view_definition, 901, 900)", fixed = TRUE)
})

test_that("Databricks descriptions retain columns and nullability", {
  rows <- data.frame(
    col_name = c(
      "Order ID",
      "notes",
      "# Partition Information",
      "notes"
    ),
    data_type = c("bigint", "string", "", "string"),
    comment = c("Primary key", NA, "", NA),
    stringsAsFactors = FALSE
  )
  nullable <- c("Order ID" = FALSE, notes = TRUE)

  columns <- databricks_columns_from_describe(rows, nullable)

  expect_equal(columns$column, c("Order ID", "notes"))
  expect_equal(columns$type, c("bigint", "string"))
  expect_identical(columns$nullable, c(FALSE, TRUE))
  expect_equal(columns$description, c("Primary key", NA))
})

test_that("Databricks identifiers distinguish namespaces and relations", {
  expect_equal(databricks_id_type(DBI::Id(catalog = "main")), "namespace")
  expect_equal(databricks_id_type(DBI::Id(schema = "default")), "namespace")
  expect_equal(
    databricks_id_type(DBI::Id(catalog = "main", schema = "default")),
    "namespace"
  )
  expect_equal(databricks_id_type(DBI::Id(table = "orders")), "relation")
  expect_equal(
    databricks_id_type(DBI::Id(schema = "default", table = "orders")),
    "relation"
  )
})

test_that("Databricks identifiers cannot skip components", {
  expect_snapshot(
    databricks_id_type(DBI::Id(catalog = "main", table = "orders")),
    error = TRUE
  )
})

test_that("Databricks current namespace requires a catalog and schema", {
  local_mocked_bindings(
    dbGetQuery = function(...) {
      data.frame(catalog = NA_character_, schema = NA_character_)
    },
    .package = "DBI"
  )

  expect_snapshot(
    databricks_current_namespace(NULL),
    error = TRUE
  )
})

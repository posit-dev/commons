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

test_that("Databricks normalizes information schema names before ODBC lookup", {
  schemas <- NULL
  local_mocked_bindings(
    dbGetQuery = function(...) {
      data.frame(
        TABLE_CATALOG = "main",
        TABLE_SCHEMA = "analytics",
        TABLE_NAME = "sales_metrics",
        TABLE_TYPE = "VIEW",
        COMMENT = "",
        stringsAsFactors = FALSE
      )
    },
    .package = "DBI"
  )
  local_mocked_bindings(
    databricks_odbc_object_types = function(con, catalog, candidate_schemas) {
      schemas <<- candidate_schemas
      stats::setNames(
        "metric view",
        databricks_object_key("analytics", "sales_metrics")
      )
    }
  )

  relations <- databricks_list_unity_relations(
    DBI::ANSI(),
    DBI::Id(catalog = "main", schema = "analytics")
  )

  expect_equal(schemas, "analytics")
  expect_equal(relations[[1]]$kind, "metric_view")
})

test_that("Databricks metric YAML expands wildcard fields from metadata", {
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
  columns <- list(
    list(
      name = "order_id",
      type = list(name = "bigint"),
      comment = "Order identifier."
    ),
    list(name = "region", type = list(name = "string")),
    list(
      name = "order_count",
      type = list(name = "bigint"),
      is_measure = TRUE
    )
  )

  model <- databricks_semantic_model_from_spec(
    id,
    specification,
    columns = columns
  )

  expect_s3_class(model, "commons_semantic_model")
  expect_equal(model$backend, "databricks_metric_view")
  expect_equal(model$description, "Governed sales metrics.")
  expect_equal(
    vapply(model$dimensions, `[[`, character(1), "name"),
    c("region", "order_id")
  )
  expect_equal(model$dimensions[[1]]$label, "Sales Region")
  expect_equal(model$dimensions[[1]]$synonyms, c("territory", "market"))
  expect_equal(model$dimensions[[2]]$type, "bigint")
  expect_equal(model$dimensions[[2]]$description, "Order identifier.")
  expect_equal(
    vapply(model$metrics, `[[`, character(1), "name"),
    "order_count"
  )
})

test_that("Databricks metric scope retains source and join dependencies", {
  specification <- list(
    version = 1.1,
    comment = "Governed order metrics.",
    ai_context = "Treat returned orders as active.",
    source = "main.sales.orders",
    filter = "source.is_active",
    joins = list(list(
      name = "customer",
      source = "main.sales.customers",
      on = "source.customer_id = customer.id",
      joins = list(list(
        name = "region",
        source = "`main`.`sales`.`sales regions`",
        using = "region_id"
      ))
    )),
    fields = list(list(name = "region", expr = "region.name")),
    measures = list(list(name = "revenue", expr = "SUM(source.revenue)"))
  )
  id <- DBI::Id(
    catalog = "main",
    schema = "sales",
    table = "order_metrics"
  )

  model <- databricks_semantic_model_from_spec(id, specification)

  expect_true(model$dependencies_complete)
  expect_equal(
    vapply(model$dependencies, table_id_label, character(1)),
    c(
      "main.sales.orders",
      "main.sales.customers",
      "main.sales.sales regions"
    )
  )
  expect_equal(model$relationships, specification$joins)
  expect_equal(model$filters, list("source.is_active"))
  expect_true(any(grepl("Treat returned orders", model$context$retrieval)))
  expect_true(any(grepl("customer", model$context$first_touch)))
  expect_true(any(grepl("sales regions", model$context$retrieval)))
})

test_that("Databricks query-backed metrics fail closed for association", {
  model <- databricks_semantic_model_from_spec(
    DBI::Id(catalog = "main", schema = "sales", table = "order_metrics"),
    list(
      version = 1.1,
      source = "SELECT * FROM main.sales.orders",
      measures = list(list(name = "orders", expr = "COUNT(1)"))
    )
  )

  expect_false(model$dependencies_complete)
  expect_false(semantic_model_in_scope(
    model,
    list(list(id = DBI::Id(
      catalog = "main",
      schema = "sales",
      table = "orders"
    )))
  ))
})

test_that("Databricks rejects metric semantics it cannot query faithfully", {
  id <- DBI::Id(
    catalog = "main",
    schema = "analytics",
    table = "sales_metrics"
  )

  expect_error(
    databricks_semantic_model_from_spec(
      id,
      list(
        version = 1.1,
        parameters = list(list(name = "minimum_amount")),
        measures = list(list(name = "revenue", expr = "SUM(revenue)"))
      )
    ),
    "Parameterized Databricks metric views are not supported",
    fixed = TRUE
  )
  expect_error(
    databricks_semantic_model_from_spec(
      id,
      list(version = 1.1, fields = list(list(expr = "source.*")))
    ),
    "wildcard members require concrete column metadata",
    fixed = TRUE
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

test_that("Snowflake SHOW results retain native relation metadata", {
  rows <- data.frame(
    name = c("Sales.Report", "ORDERS", "STAGE"),
    database_name = c("Data.Base", "ANALYTICS", "ANALYTICS"),
    schema_name = c("Odd Schema", "PUBLIC", "PUBLIC"),
    kind = c("VIEW", "TABLE", "STAGE"),
    comment = c("A useful view", "", "Ignored"),
    stringsAsFactors = FALSE
  )

  relations <- snowflake_relations_from_show(rows)

  expect_length(relations, 2)
  expect_equal(relations[[1]]$kind, "view")
  expect_equal(relations[[1]]$description, "A useful view")
  expect_null(relations[[2]]$description)
  expect_identical(
    relations[[1]]$id,
    DBI::Id(
      catalog = "Data.Base",
      schema = "Odd Schema",
      table = "Sales.Report"
    )
  )

  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(
    as.character(DBI::dbQuoteIdentifier(con, relations[[1]]$id)),
    '"Data.Base"."Odd Schema"."Sales.Report"'
  )
})

test_that("Snowflake SHOW results identify semantic views separately", {
  rows <- data.frame(
    name = c("REVENUE_MODEL", "FINANCE_MODEL"),
    database_name = "ANALYTICS",
    schema_name = "PUBLIC",
    comment = c("Revenue semantics", ""),
    stringsAsFactors = FALSE
  )

  views <- snowflake_semantic_views_from_show(rows)

  expect_length(views, 2L)
  expect_identical(
    views[[1]]$id,
    DBI::Id(
      catalog = "ANALYTICS",
      schema = "PUBLIC",
      table = "REVENUE_MODEL"
    )
  )
  expect_equal(views[[1]]$description, "Revenue semantics")
  expect_null(views[[2]]$description)
})

test_that("Snowflake semantic YAML imports only public dimensions and metrics", {
  specification <- list(
    name = "revenue",
    description = "Revenue model.",
    tables = list(
      orders = list(
        dimensions = list(
          region = list(description = "Sales region."),
          secret = list(access_modifier = "private_access")
        ),
        time_dimensions = list(
          ordered_at = list(data_type = "TIMESTAMP")
        ),
        metrics = list(
          order_count = list(description = "Orders.")
        )
      )
    ),
    metrics = list(
      list(name = "total_revenue", description = "Revenue.")
    )
  )
  id <- DBI::Id(
    catalog = "ANALYTICS",
    schema = "PUBLIC",
    table = "REVENUE_MODEL"
  )

  model <- snowflake_semantic_model_from_spec(id, specification)

  expect_s3_class(model, "commons_semantic_model")
  expect_equal(model$name, "revenue")
  expect_equal(
    vapply(model$dimensions, `[[`, character(1), "name"),
    c("region", "ordered_at")
  )
  expect_equal(
    vapply(model$metrics, `[[`, character(1), "name"),
    c("order_count", "total_revenue")
  )
  expect_equal(model$dimensions[[1]]$parent, "orders")
  expect_equal(model$metrics[[1]]$parent, "orders")
})

test_that("Snowflake semantic SQL uses model-owned references", {
  model <- test_semantic_model()
  registry <- semantic_models_registry(list(
    sales_db = structure(
      list(
        semantic_models = stats::setNames(
          list(model),
          table_id_label(model$id)
        )
      ),
      class = "commons_data_source"
    )
  ))
  members <- registry_semantic_members(registry)
  metrics <- members[members$kind == "metric", , drop = FALSE]
  dimensions <- members[members$kind == "dimension", , drop = FALSE]
  con <- DBI::ANSI()

  sql <- snowflake_semantic_metric_sql(
    model,
    metrics,
    dimensions,
    where = NULL,
    members = members,
    con = con
  )

  expect_equal(
    sql,
    paste0(
      "SELECT * FROM SEMANTIC_VIEW(\n",
      "  \"ANALYTICS\".\"PUBLIC\".\"revenue_model\"\n",
      "  DIMENSIONS \"orders\".\"region\"\n",
      "  METRICS \"total_revenue\"\n",
      ")"
    )
  )
})

test_that("semantic views are excluded from namespace relations", {
  registry <- list(
    labels = c("DB.PUBLIC.orders", "DB.PUBLIC.model"),
    ids = list(
      "DB.PUBLIC.orders" = DBI::Id(table = "orders"),
      "DB.PUBLIC.model" = DBI::Id(table = "model")
    ),
    relations = list(
      "DB.PUBLIC.orders" = list(kind = "table"),
      "DB.PUBLIC.model" = list(kind = "view")
    ),
    validate = list(
      labels = "DB.PUBLIC.model",
      ids = list("DB.PUBLIC.model" = DBI::Id(table = "model"))
    )
  )

  registry <- catalog_exclude_relations(registry, "DB.PUBLIC.model")

  expect_equal(registry$labels, "DB.PUBLIC.orders")
  expect_named(registry$ids, "DB.PUBLIC.orders")
  expect_named(registry$relations, "DB.PUBLIC.orders")
  expect_length(registry$validate$labels, 0L)
  expect_length(registry$validate$ids, 0L)
})

test_that("Snowflake identifiers distinguish namespaces and relations", {
  expect_equal(snowflake_id_type(DBI::Id(catalog = "DB")), "namespace")
  expect_equal(snowflake_id_type(DBI::Id(schema = "PUBLIC")), "namespace")
  expect_equal(
    snowflake_id_type(DBI::Id(catalog = "DB", schema = "PUBLIC")),
    "namespace"
  )
  expect_equal(snowflake_id_type(DBI::Id(table = "ORDERS")), "relation")
  expect_equal(
    snowflake_id_type(DBI::Id(schema = "PUBLIC", table = "ORDERS")),
    "relation"
  )
  expect_error(
    snowflake_id_type(DBI::Id(catalog = "DB", table = "ORDERS")),
    "without skipped"
  )
  expect_error(
    snowflake_id_type(DBI::Id(schema = "", table = "ORDERS")),
    "without skipped"
  )
})

test_that("Snowflake current namespace requires a database and schema", {
  local_mocked_bindings(
    dbGetQuery = function(...) {
      data.frame(catalog = NA_character_, schema = NA_character_)
    },
    .package = "DBI"
  )

  expect_snapshot(
    snowflake_current_namespace(NULL),
    error = TRUE
  )
})

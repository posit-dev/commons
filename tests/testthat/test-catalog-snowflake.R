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

test_that("Snowflake semantic scope retains dependencies and public context", {
  specification <- list(
    custom_instructions = "Use booked revenue for finance questions.",
    tables = list(
      orders = list(
        base_table = list(
          database = "ANALYTICS",
          schema = "PUBLIC",
          table = "ORDERS"
        ),
        dimensions = list(
          list(
            name = "active_only",
            labels = "filter",
            description = "Active orders."
          )
        ),
        facts = list(
          list(
            name = "amount",
            description = "Order amount.",
            labels = "filter"
          ),
          list(name = "cost", access_modifier = "private_access")
        ),
        filters = list(
          list(name = "recent_only", description = "Recent orders.")
        ),
        metrics = list(
          list(name = "revenue"),
          list(name = "margin", access_modifier = "private_access")
        )
      )
    ),
    relationships = list(list(
      name = "orders_to_customers",
      left_table = "orders",
      right_table = "customers",
      relationship_columns = list(list(
        left_column = "customer_id",
        right_column = "id"
      ))
    ))
  )
  id <- DBI::Id(
    catalog = "ANALYTICS",
    schema = "PUBLIC",
    table = "REVENUE_MODEL"
  )

  model <- snowflake_semantic_model_from_spec(id, specification)

  expect_true(model$dependencies_complete)
  expect_identical(
    model$dependencies[[1]],
    DBI::Id(catalog = "ANALYTICS", schema = "PUBLIC", table = "ORDERS")
  )
  expect_equal(
    vapply(model$facts, `[[`, character(1), "name"),
    "amount"
  )
  expect_equal(
    vapply(model$metrics, `[[`, character(1), "name"),
    "revenue"
  )
  expect_true(model$dimensions[[1]]$filter)
  expect_true(model$facts[[1]]$filter)
  expect_equal(model$relationships, specification$relationships)
  expect_true(any(grepl("booked revenue", model$context$first_touch)))
  expect_true(any(grepl("orders_to_customers", model$context$retrieval)))
  expect_true(any(grepl("Order amount", model$context$retrieval)))
  expect_true(any(grepl("recent_only", model$context$retrieval)))

  source <- test_source()
  source$semantic_models <- list(revenue = model)
  members <- registry_semantic_members(
    semantic_models_registry(list(snowflake = source))
  )
  expect_contains(members$name[members$filter], c("active_only", "amount"))
  expect_false("recent_only" %in% members$name)
})

test_that("Snowflake associated discovery uses canonical model identities", {
  dependency <- DBI::Id(
    catalog = "ANALYTICS",
    schema = "PUBLIC",
    table = "ORDERS"
  )
  identity <- DBI::Id(
    catalog = "ANALYTICS",
    schema = "PUBLIC",
    table = "REVENUE_MODEL"
  )
  model <- new_semantic_model(
    DBI::Id(table = "REVENUE_MODEL"),
    "revenue",
    backend = "snowflake_semantic_view",
    identity = identity,
    dependencies = list(dependency)
  )
  registry <- list(
    relations = list(orders = list(
      id = DBI::Id(table = "ORDERS"),
      identity = dependency,
      kind = "table"
    )),
    validate = list(labels = "orders"),
    semantic_models = list(REVENUE_MODEL = model)
  )
  local_mocked_bindings(
    snowflake_list_semantic_views = function(...) {
      list(list(id = identity, description = NULL))
    },
    snowflake_read_semantic_model = function(...) {
      cli::cli_abort("Duplicate model was read.")
    }
  )

  expect_length(
    snowflake_associated_semantic_models(DBI::ANSI(), registry),
    0L
  )
})

test_that("Snowflake association closes over every selected relation", {
  orders <- DBI::Id(
    catalog = "ANALYTICS",
    schema = "SALES",
    table = "ORDERS"
  )
  customers <- DBI::Id(
    catalog = "ANALYTICS",
    schema = "SHARED",
    table = "CUSTOMERS"
  )
  view <- list(id = DBI::Id(
    catalog = "ANALYTICS",
    schema = "SALES",
    table = "REVENUE_MODEL"
  ))
  model <- new_semantic_model(
    view$id,
    "revenue",
    backend = "snowflake_semantic_view",
    dependencies = list(orders, customers)
  )
  registry <- list(
    relations = list(
      orders = list(id = DBI::Id(table = "ORDERS"), identity = orders, kind = "table"),
      customers = list(id = customers, kind = "table")
    ),
    validate = list(labels = "orders"),
    semantic_models = list()
  )
  local_mocked_bindings(
    snowflake_list_semantic_views = function(...) list(view),
    snowflake_read_semantic_model = function(...) model
  )

  associated <- snowflake_associated_semantic_models(DBI::ANSI(), registry)
  expect_named(associated, "ANALYTICS.SALES.REVENUE_MODEL")

  registry$relations$orders <- list(id = DBI::Id(table = "MISSING"), kind = NULL)
  expect_length(
    snowflake_associated_semantic_models(DBI::ANSI(), registry),
    0L
  )
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

test_that("Snowflake semantic SQL applies named entity filters", {
  model <- snowflake_semantic_model_from_spec(
    DBI::Id(
      catalog = "ANALYTICS",
      schema = "PUBLIC",
      table = "REVENUE_MODEL"
    ),
    list(tables = list(list(
      name = "orders",
      base_table = list(
        database = "ANALYTICS",
        schema = "PUBLIC",
        table = "ORDERS"
      ),
      dimensions = list(list(
        name = "active_only",
        labels = "filter"
      )),
      metrics = list(list(name = "revenue"))
    )))
  )
  source <- test_source()
  source$semantic_models <- list(model = model)
  members <- registry_semantic_members(
    semantic_models_registry(list(snowflake = source))
  )
  metrics <- members[members$kind == "metric", , drop = FALSE]
  filters <- resolve_semantic_filters("active_only", members)

  sql <- snowflake_semantic_metric_sql(
    model,
    metrics,
    dimensions = members[0, , drop = FALSE],
    filters = filters,
    where = NULL,
    members = members,
    con = DBI::ANSI()
  )

  expect_match(sql, 'WHERE "orders"."active_only"', fixed = TRUE)
})

test_that("Snowflake imports and binds semantic variables", {
  model <- snowflake_semantic_model_from_spec(
    DBI::Id(
      catalog = "ANALYTICS",
      schema = "PUBLIC",
      table = "REVENUE_MODEL"
    ),
    list(
      variables = list(
        list(
          name = "threshold",
          data_type = "NUMBER(5,1)",
          default_value = "42",
          description = "Minimum revenue."
        ),
        list(name = "category", data_type = "TEXT")
      ),
      metrics = list(list(name = "revenue"))
    )
  )
  source <- test_source()
  source$semantic_models <- list(model = model)
  members <- registry_semantic_members(
    semantic_models_registry(list(snowflake = source))
  )
  metrics <- members[members$kind == "metric", , drop = FALSE]
  sql <- snowflake_semantic_metric_sql(
    model,
    metrics,
    members[0, , drop = FALSE],
    where = NULL,
    members = members,
    con = DBI::ANSI(),
    arguments = list(category = "retail")
  )

  expect_equal(model$parameters$threshold$type, "number")
  expect_equal(model$parameters$threshold$default, 42)
  expect_false(model$parameters$category$has_default)
  expect_match(sql, 'VARIABLES "category" => ?', fixed = TRUE)
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

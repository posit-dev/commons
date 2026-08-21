test_that("semantic model registries remain separate from definitions", {
  source <- test_semantic_source()
  registry <- semantic_models_registry(list(sales_db = source))
  members <- registry_semantic_members(registry)

  expect_equal(members$name, c("region", "total_revenue"))
  expect_equal(members$kind, c("dimension", "metric"))
  expect_equal(members$source, rep("sales_db", 2))
  expect_equal(members$model, rep("ANALYTICS.PUBLIC.revenue_model", 2))
  expect_equal(members$parent, c("orders", NA_character_))
  expect_true(semantic_registry_has_metrics(registry))
  expect_length(source$dictionary$tables$sales$definitions, 0L)
})

test_that("semantic members resolve by model and logical-table aliases", {
  source <- test_semantic_source()
  second <- test_semantic_model("finance_model", "total_revenue")
  source$semantic_models[[table_id_label(second$id)]] <- second
  members <- registry_semantic_members(
    semantic_models_registry(list(sales_db = source))
  )

  expect_error(
    resolve_semantic_member("total_revenue", members, "metric"),
    "ambiguous"
  )
  resolved <- resolve_semantic_member(
    "ANALYTICS.PUBLIC.revenue_model::total_revenue",
    members,
    "metric"
  )
  expect_equal(resolved$model, "ANALYTICS.PUBLIC.revenue_model")

  expect_error(
    resolve_semantic_member("orders.region", members, "dimension"),
    "ambiguous"
  )
  dimension <- resolve_semantic_member(
    "ANALYTICS.PUBLIC.revenue_model::orders.region",
    members,
    "dimension"
  )
  expect_equal(dimension$parent, "orders")
})

test_that("associated semantic models require their complete dependency closure", {
  orders <- DBI::Id(catalog = "main", schema = "sales", table = "orders")
  customers <- DBI::Id(
    catalog = "main",
    schema = "sales",
    table = "customers"
  )
  model <- new_semantic_model(
    DBI::Id(catalog = "main", schema = "sales", table = "sales_metrics"),
    "sales_metrics",
    backend = "databricks_metric_view",
    dependencies = list(orders, customers)
  )
  selected <- list(
    orders = list(id = orders),
    customers = list(id = customers)
  )

  expect_true(semantic_model_in_scope(model, selected))
  expect_false(semantic_model_in_scope(model, selected["orders"]))
  model$dependencies_complete <- FALSE
  expect_false(semantic_model_in_scope(model, selected))
})

test_that("semantic model context follows selected dependency tables", {
  orders <- DBI::Id(
    catalog = "ANALYTICS",
    schema = "PUBLIC",
    table = "ORDERS"
  )
  model <- new_semantic_model(
    DBI::Id(
      catalog = "ANALYTICS",
      schema = "PUBLIC",
      table = "REVENUE_MODEL"
    ),
    "revenue_model",
    backend = "snowflake_semantic_view",
    dependencies = list(orders),
    context = list(
      first_touch = "Use booked revenue.",
      retrieval = "Orders join customers by customer ID."
    )
  )
  source <- test_source()
  source$relations <- list(orders = list(id = orders))
  source$semantic_models <- list(revenue = model)

  expect_equal(
    semantic_model_first_touch(source, "orders"),
    "Use booked revenue."
  )
  layer <- augment_context_layer(NULL, list(warehouse = source))
  expect_contains(layer$docs, "Orders join customers by customer ID.")
})

test_that("semantic first-touch context is delivered once across SQL tools", {
  source <- test_source()
  id <- source$table_ids$sales
  source$relations <- list(sales = list(
    id = id,
    kind = "table",
    description = NULL,
    columns = data.frame(
      column = names(test_sales()),
      type = vapply(test_sales(), function(x) class(x)[[1]], character(1))
    )
  ))
  source$semantic_models <- list(revenue = new_semantic_model(
    DBI::Id(table = "revenue_model"),
    "revenue_model",
    backend = "snowflake_semantic_view",
    dependencies = list(id),
    context = list(first_touch = "Use booked revenue.")
  ))

  tracker <- new.env(parent = emptyenv())
  first <- describe_table_tool(source, "sales", tracker = tracker)
  second <- describe_table_tool(source, "sales", tracker = tracker)
  expect_match(first@value, "Use booked revenue.", fixed = TRUE)
  expect_no_match(second@value, "Use booked revenue.", fixed = TRUE)

  tracker <- new.env(parent = emptyenv())
  first <- run_sql_tool(
    source,
    "SELECT * FROM sales LIMIT 1",
    tracker = tracker
  )
  second <- run_sql_tool(
    source,
    "SELECT * FROM sales LIMIT 1",
    tracker = tracker
  )
  expect_match(first@value, "Use booked revenue.", fixed = TRUE)
  expect_no_match(second@value, "Use booked revenue.", fixed = TRUE)
})

test_that("native semantic members appear in pool search", {
  registry <- semantic_models_registry(list(sales_db = test_semantic_source()))
  out <- search_pool_text(
    list(),
    empty_definitions(),
    "revenue by region",
    semantic_models = registry
  )

  expect_match(out, "native metric", fixed = TRUE)
  expect_match(out, "total_revenue", fixed = TRUE)
  expect_match(out, "call_metrics dimension: region", fixed = TRUE)
})

test_that("unhydrated semantic models are searchable and describable", {
  source <- test_source()
  model <- test_semantic_model()
  label <- table_id_label(model$id)
  source$semantic_stubs <- stats::setNames(list(
    new_semantic_model_stub(
      list(id = model$id, description = model$description),
      "snowflake_semantic_view"
    )
  ), label)
  reads <- 0L
  local_mocked_bindings(
    snowflake_read_semantic_model = function(...) {
      reads <<- reads + 1L
      model
    }
  )

  registry <- semantic_models_registry(list(sales_db = source))
  search <- search_pool_text(
    list(),
    empty_definitions(),
    "revenue semantics",
    semantic_models = registry
  )
  description <- source_describe(source, label)
  text <- semantic_model_description_text(description)

  expect_match(search, label, fixed = TRUE)
  expect_match(search, "Inspect with `describe_table`", fixed = TRUE)
  expect_match(text, paste0(label, "::total_revenue"), fixed = TRUE)
  expect_length(source$semantic_models, 0L)
  expect_equal(reads, 1L)
})

test_that("eager semantic models are describable without rereading metadata", {
  source <- test_semantic_source()
  label <- names(source$semantic_models)[[1]]
  local_mocked_bindings(
    snowflake_read_semantic_model = function(...) {
      cli::cli_abort("Semantic model metadata was read again.")
    }
  )

  description <- source_describe(source, label)

  expect_s3_class(description, "commons_semantic_model_description")
  expect_match(
    semantic_model_description_text(description),
    paste0(label, "::total_revenue"),
    fixed = TRUE
  )
})

test_that("semantic model descriptions retain unreadable catalog entries", {
  source <- test_source()
  model <- test_semantic_model()
  label <- table_id_label(model$id)
  source$semantic_stubs <- stats::setNames(list(
    new_semantic_model_stub(
      list(id = model$id, description = model$description),
      "snowflake_semantic_view"
    )
  ), label)
  local_mocked_bindings(
    snowflake_read_semantic_model = function(...) {
      cli::cli_abort("The current role cannot read this definition.")
    }
  )

  result <- describe_table_tool(source, label)

  expect_match(result@value, "is listed in the catalog", fixed = TRUE)
  expect_match(result@value, "current role cannot read", fixed = TRUE)
})

test_that("lazy semantic metrics hydrate from qualified names", {
  source <- test_source()
  model <- test_semantic_model()
  label <- table_id_label(model$id)
  source$semantic_stubs <- stats::setNames(list(
    new_semantic_model_stub(
      list(id = model$id, description = model$description),
      "snowflake_semantic_view"
    )
  ), label)
  query <- NULL
  local_mocked_bindings(
    snowflake_read_semantic_model = function(...) model,
    source_query_bind = function(source, sql, bindings) {
      query <<- sql
      data.frame(total_revenue = 42)
    }
  )
  sources <- list(sales_db = source)

  result <- call_metrics_impl(
    empty_definitions(),
    sources,
    new_handle_store(),
    metrics = paste0(label, "::total_revenue"),
    semantic_models = semantic_models_registry(sources)
  )

  expect_match(query, "FROM SEMANTIC_VIEW", fixed = TRUE)
  expect_equal(result@extra$commons_tag, "A")
})

test_that("semantic stubs earn fixed execution tools", {
  source <- test_source()
  model <- test_semantic_model()
  label <- table_id_label(model$id)
  source$semantic_stubs <- stats::setNames(list(
    new_semantic_model_stub(
      list(id = model$id, description = model$description),
      "snowflake_semantic_view"
    )
  ), label)
  agent <- test_agent(data_sources = list(sales_db = source))
  tools <- vapply(agent$get_tools(), tool_name, character(1))

  expect_contains(tools, "search_pool")
  expect_contains(tools, "call_metrics")
  expect_contains(tools, "call_calculation")
})

test_that("pool search identifies native members' data sources", {
  registry <- semantic_models_registry(list(
    warehouse = test_semantic_source(),
    finance = test_semantic_source()
  ))
  out <- search_pool_text(
    list(),
    empty_definitions(),
    "total revenue",
    source_names = c("warehouse", "finance"),
    semantic_models = registry
  )

  expect_match(out, "sources: warehouse", fixed = TRUE)
  expect_match(out, "sources: finance", fixed = TRUE)
})

test_that("call_metrics dispatches native metrics through their model", {
  source <- test_semantic_source()
  sources <- list(sales_db = source)
  registry <- semantic_models_registry(sources)
  handles <- new_handle_store()
  query <- NULL
  local_mocked_bindings(
    source_query = function(source, sql) {
      query <<- sql
      data.frame(total_revenue = 42)
    }
  )

  result <- call_metrics_impl(
    empty_definitions(),
    sources,
    handles,
    metrics = "total_revenue",
    dimensions = "region",
    where = list(list(column = "region", op = "=", value = "EMEA")),
    semantic_models = registry
  )

  expect_match(query, "FROM SEMANTIC_VIEW", fixed = TRUE)
  expect_match(query, "DIMENSIONS orders.region", fixed = TRUE)
  expect_match(query, "METRICS total_revenue", fixed = TRUE)
  expect_match(query, "WHERE (orders.region = 'EMEA')", fixed = TRUE)
  expect_equal(get_handle(handles, "r1")$total_revenue, 42)
  expect_equal(result@extra$commons_tag, "A")
})

test_that("call_metrics does not mix native and data-dict metrics", {
  source <- definitions_source()
  model <- test_semantic_model()
  source$semantic_models[[table_id_label(model$id)]] <- model
  sources <- list(sales_db = source)

  expect_error(
    call_metrics_impl(
      definitions_registry(sources),
      sources,
      new_handle_store(),
      metrics = c("big_revenue", "total_revenue"),
      semantic_models = semantic_models_registry(sources)
    ),
    "either data-dict definitions or one native semantic model"
  )
})

test_that("call_metrics validates and binds native parameters", {
  source <- test_semantic_source()
  model <- source$semantic_models[[1]]
  model$parameters <- list(threshold = new_typed_argument(
    "threshold",
    "number"
  ))
  source$semantic_models[[1]] <- model
  sources <- list(sales_db = source)
  semantic_registry <- semantic_models_registry(sources)
  query <- NULL
  bindings <- NULL
  local_mocked_bindings(
    source_query_bind = function(source, sql, values) {
      query <<- sql
      bindings <<- values
      data.frame(total_revenue = 42)
    }
  )

  result <- call_metrics_impl(
    empty_definitions(),
    sources,
    new_handle_store(),
    metrics = "total_revenue",
    semantic_models = semantic_registry,
    arguments = '{"threshold":100}'
  )

  expect_match(query, "VARIABLES threshold => ?", fixed = TRUE)
  expect_equal(bindings, list(100))
  expect_equal(result@extra$commons_tag, "A")
  search <- search_pool_text(
    list(),
    empty_definitions(),
    "total revenue threshold",
    semantic_models = semantic_registry
  )
  expect_match(search, "`threshold` (number, required)", fixed = TRUE)
  expect_error(
    call_metrics_impl(
      empty_definitions(),
      sources,
      new_handle_store(),
      metrics = "total_revenue",
      semantic_models = semantic_registry,
      arguments = '{"threshold":"high"}'
    ),
    "must be a number"
  )
})

test_that("native semantic metrics add pool and metric tools", {
  agent <- test_agent(
    data_sources = list(sales_db = test_semantic_source())
  )
  tools <- vapply(agent$get_tools(), tool_name, character(1))

  expect_contains(tools, "search_pool")
  expect_contains(tools, "call_metrics")
})

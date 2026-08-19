test_that("catalog manifests switch broad prompts to search", {
  local_mocked_bindings(catalog_prompt_limit = 1L)
  source <- test_source()
  id <- source$table_ids$sales
  source$relations <- list(sales = list(
    id = id,
    kind = "table",
    description = "Booked sales activity.",
    columns = NULL
  ))
  source$manifest <- new_catalog_manifest(source$relations, TRUE)
  agent <- test_agent(data_sources = list(warehouse = source))

  expect_match(
    agent$get_system_prompt(),
    "Use `search_catalog` to find tables",
    fixed = TRUE
  )
  expect_no_match(agent$get_system_prompt(), "- sales", fixed = TRUE)
  expect_contains(
    vapply(agent$get_tools(), tool_name, character(1)),
    "search_catalog"
  )
})

test_that("catalog search finds relation names and descriptions", {
  source <- test_source()
  source$manifest <- new_catalog_manifest(list(
    "main.finance.orders" = list(
      id = DBI::Id(catalog = "main", schema = "finance", table = "orders"),
      kind = "table",
      description = "Booked commercial activity."
    ),
    refunds = list(
      id = DBI::Id(table = "refunds"),
      kind = "view",
      description = "Returned purchases."
    )
  ), TRUE)
  source$manifest$searchable <- TRUE

  expect_named(
    catalog_search(source, "commercial bookings"),
    "main.finance.orders"
  )
  expect_named(catalog_search(source, "finance"), "main.finance.orders")
  expect_named(catalog_search(source, "refund"), "refunds")
  expect_length(catalog_search(source, "refund", kinds = "table"), 0L)
  expect_length(catalog_search(source, ""), 0L)
})

test_that("catalog search results are ready for describe_table", {
  source <- test_source()
  source$relations <- list(sales = list(
    id = source$table_ids$sales,
    kind = "table",
    description = "Booked sales activity.",
    columns = NULL
  ))
  source$manifest <- new_catalog_manifest(source$relations, TRUE)
  source$manifest$searchable <- TRUE
  private <- list(
    sources = list(warehouse = source),
    first_touch = new.env(parent = emptyenv())
  )

  search <- tool_search_catalog(private)
  result <- search("booked")

  expect_match(result@value, "`sales` (table)", fixed = TRUE)
  expect_match(result@value, "Booked sales activity.", fixed = TRUE)
})

test_that("catalog descriptions hydrate columns only once", {
  source <- test_source()
  source$relations <- list(sales = list(
    id = source$table_ids$sales,
    kind = "table",
    description = "Booked sales activity.",
    columns = NULL
  ))
  source$manifest <- new_catalog_manifest(source$relations, TRUE)
  described <- 0L
  schema <- data.frame(column = "order_id", type = "VARCHAR")
  local_mocked_bindings(
    databricks_describe_relation = function(...) {
      described <<- described + 1L
      schema
    }
  )

  expect_null(source$manifest$relations$sales$columns)
  source_describe(source, "sales")
  source_describe(source, "sales")

  expect_equal(described, 1L)
  expect_identical(source$manifest$relations$sales$columns, schema)
})

test_that("catalog selection supports exclusions and an object cap", {
  relations <- list(
    list(
      id = DBI::Id(catalog = "main", schema = "sales", table = "orders"),
      kind = "table",
      description = NULL
    ),
    list(
      id = DBI::Id(catalog = "main", schema = "sales", table = "TMP_LOAD"),
      kind = "table",
      description = NULL
    )
  )
  registry <- catalog_table_registry(
    DBI::ANSI(),
    DBI::Id(catalog = "main", schema = "sales"),
    current_namespace = function(...) NULL,
    id_type = function(...) "namespace",
    exact_relation = function(...) NULL,
    list_relations = function(...) relations,
    exclude = "TMP_*"
  )

  expect_named(registry$relations, "main.sales.orders")
  expect_true(registry$namespace_selected)

  local_mocked_bindings(catalog_object_limit = 1L)
  expect_no_error(catalog_table_registry(
    DBI::ANSI(),
    DBI::Id(catalog = "main", schema = "sales"),
    current_namespace = function(...) NULL,
    id_type = function(...) "namespace",
    exact_relation = function(...) NULL,
    list_relations = function(...) relations,
    exclude = "TMP_*"
  ))
  expect_error(
    catalog_table_registry(
      DBI::ANSI(),
      DBI::Id(catalog = "main", schema = "sales"),
      current_namespace = function(...) NULL,
      id_type = function(...) "namespace",
      exact_relation = function(...) NULL,
      list_relations = function(...) relations
    ),
    "above the supported limit"
  )
})

test_that("associated model candidates are bounded before hydration", {
  dependency <- DBI::Id(
    catalog = "main",
    schema = "sales",
    table = "orders"
  )
  candidates <- lapply(c("MODEL_A", "MODEL_B"), function(name) {
    list(
      id = DBI::Id(catalog = "main", schema = "sales", table = name),
      kind = "metric_view"
    )
  })
  registry <- list(
    relations = list(orders = list(
      id = dependency,
      identity = dependency,
      kind = "table"
    )),
    validate = list(labels = "orders"),
    semantic_models = list()
  )
  local_mocked_bindings(
    catalog_object_limit = 2L,
    databricks_list_relations = function(...) candidates,
    databricks_read_semantic_model = function(view, ...) {
      new_semantic_model(
        view$id,
        view$id@name[["table"]],
        backend = "databricks_metric_view",
        dependencies = list(dependency)
      )
    }
  )

  expect_error(
    databricks_associated_semantic_models(DBI::ANSI(), registry),
    "above the supported limit"
  )
  expect_named(
    databricks_associated_semantic_models(
      DBI::ANSI(),
      registry,
      exclude = "MODEL_B"
    ),
    "main.sales.MODEL_A"
  )
})

test_that("catalog exclusion globs are validated", {
  expect_equal(
    catalog_excluded(c("TMP_ONE", "orders", "stage1"), c("TMP_*", "stage?")),
    c(TRUE, FALSE, TRUE)
  )
  expect_error(check_catalog_exclude(NA_character_), "without missing")
  expect_error(data_source(orders = data.frame(id = 1), exclude = "orders"))
})

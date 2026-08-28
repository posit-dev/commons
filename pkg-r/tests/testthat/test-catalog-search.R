test_that("catalog manifests switch broad prompts to search", {
  local_mocked_bindings(catalog_prompt_limit = 1L)
  source <- test_source()
  state <- data_source_state(source)
  id <- state$table_ids$sales
  state$relations <- list(sales = list(
    id = id,
    kind = "table",
    description = "Booked sales activity.",
    columns = NULL
  ))
  state$manifest <- new_catalog_manifest(state$relations, TRUE)
  agent <- test_agent(data_sources = list(warehouse = source))

  expect_match(
    agent$get_system_prompt(),
    "Use `search_catalog` to find objects",
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
  state <- data_source_state(source)
  state$manifest <- new_catalog_manifest(list(
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
  state$manifest$searchable <- TRUE

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
  state <- data_source_state(source)
  state$relations <- list(sales = list(
    id = state$table_ids$sales,
    kind = "table",
    description = "Booked sales activity.",
    columns = NULL
  ))
  state$manifest <- new_catalog_manifest(state$relations, TRUE)
  state$manifest$searchable <- TRUE
  private <- list(
    sources = list(warehouse = source),
    first_touch = new.env(parent = emptyenv())
  )

  search <- tool_search_catalog(private)
  result <- search("booked")

  expect_match(result@value, "`sales` (table)", fixed = TRUE)
  expect_match(result@value, "Booked sales activity.", fixed = TRUE)
})

test_that("catalog search hides relations without query access", {
  source <- test_source()
  state <- data_source_state(source)
  state$relations <- list(
    denied = list(
      id = DBI::Id(table = "denied"),
      kind = "table",
      description = "Restricted booked activity."
    ),
    allowed = list(
      id = DBI::Id(table = "allowed"),
      kind = "table",
      description = "Available booked activity."
    )
  )
  state$table_ids <- lapply(state$relations, `[[`, "id")
  state$manifest <- new_catalog_manifest(state$relations, TRUE)
  state$session <- list(backend = "test")
  local_mocked_bindings(
    catalog_check_session = function(...) invisible(NULL),
    catalog_ensure_queryable = function(source, table, ...) {
      if (identical(table, "denied")) {
        cli::cli_abort(
          "Not authorized.",
          class = "commons_catalog_authorization_error"
        )
      }
      invisible(source)
    }
  )

  results <- catalog_search(source, "booked")

  expect_named(results, "allowed")
  expect_equal(results$allowed$description, "Available booked activity.")
})

test_that("catalog search retains unverified semantic models", {
  source <- test_source()
  state <- data_source_state(source)
  id <- DBI::Id(catalog = "DB", schema = "PUBLIC", table = "SALES_MODEL")
  state$semantic_stubs <- list(SALES_MODEL = new_semantic_model_stub(
    list(id = id, description = "Governed sales semantics."),
    "snowflake_semantic_view"
  ))
  state$manifest <- new_catalog_manifest(
    list(),
    TRUE,
    state$semantic_stubs
  )
  state$session <- list(backend = "test")
  local_mocked_bindings(
    catalog_check_session = function(...) invisible(NULL),
    catalog_ensure_queryable = function(...) {
      cli::cli_abort("Semantic models should not be probed during search.")
    }
  )

  results <- catalog_search(source, "sales semantics")

  expect_named(results, "SALES_MODEL")
  expect_equal(results$SALES_MODEL$kind, "semantic_view")
})

test_that("catalog search formats relations with unknown kinds", {
  source <- test_source()
  state <- data_source_state(source)
  state$relations <- list(sales = list(
    id = state$table_ids$sales,
    kind = NULL,
    description = NULL
  ))
  state$manifest <- new_catalog_manifest(state$relations, TRUE)
  state$manifest$searchable <- TRUE
  private <- list(sources = list(warehouse = source))

  result <- tool_search_catalog(private)("sales")

  expect_match(result@value, "`sales` (unknown kind)", fixed = TRUE)
})

test_that("catalog descriptions hydrate columns only once", {
  source <- test_source()
  state <- data_source_state(source)
  state$relations <- list(sales = list(
    id = state$table_ids$sales,
    kind = "table",
    description = "Booked sales activity.",
    columns = NULL
  ))
  state$manifest <- new_catalog_manifest(state$relations, TRUE)
  described <- 0L
  schema <- data.frame(column = "order_id", type = "VARCHAR")
  local_mocked_bindings(
    databricks_describe_relation = function(...) {
      described <<- described + 1L
      schema
    }
  )

  expect_null(state$manifest$relations$sales$columns)
  source_describe(source, "sales")
  source_describe(source, "sales")

  expect_equal(described, 1L)
  expect_identical(state$manifest$relations$sales$columns, schema)
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

test_that("selected Snowflake models are bounded before hydration", {
  views <- lapply(c("MODEL_A", "MODEL_B"), function(name) {
    list(
      id = DBI::Id(catalog = "DB", schema = "PUBLIC", table = name),
      description = NULL
    )
  })
  local_mocked_bindings(
    catalog_object_limit = 1L,
    snowflake_catalog_selection = function(...) {
      list(relations = list(), semantic_views = views)
    },
    snowflake_read_semantic_model = function(...) {
      cli::cli_abort("Semantic model was hydrated.")
    }
  )

  expect_error(
    snowflake_table_registry(DBI::ANSI()),
    "above the supported limit"
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

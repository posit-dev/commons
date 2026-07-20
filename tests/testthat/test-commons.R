test_that("derive_tag reports how the answer was produced", {
  expect_equal(derive_tag(c("A")), "A")
  expect_equal(derive_tag(c("A", "B")), "B")
  expect_equal(derive_tag("B"), "B")
  expect_true(is.na(derive_tag(character())))
})

test_that("derive_tag_from_turns reads tags from tool result content", {
  turns <- list(
    ellmer::UserTurn("How many orders are there?"),
    ellmer::UserTurn(list(
      ellmer::ContentToolResult(
        value = "6",
        extra = list(commons_tag = "A")
      )
    )),
    ellmer::AssistantTurn("There are 6 orders.")
  )

  expect_equal(derive_tag_from_turns(turns), "A")
})

test_that("commons() returns a Chat subclass with the five fixed tools", {
  agent <- test_agent()

  expect_s3_class(agent, "Commons")
  expect_s3_class(agent, "Chat")
  expect_setequal(
    vapply(agent$get_tools(), tool_name, character(1)),
    c(
      "search_measures",
      "call_measure",
      "search_context",
      "describe_table",
      "run_sql"
    )
  )
})

test_that("the system prompt includes tables, context, and measure workflow", {
  agent <- test_agent(
    context_layer = context_layer(always = "Booked revenue excludes tax."),
    semantic_layer = semantic_layer(
      measure(
        "order_count",
        "Count of orders.",
        function() nrow(test_sales()),
        arguments = list()
      )
    )
  )
  prompt <- agent$get_system_prompt()

  expect_match(prompt, "sales")
  expect_no_match(prompt, "order_count")
  expect_match(prompt, "Booked revenue excludes tax")
  expect_match(prompt, "your first tool call must be `search_measures`")
  expect_match(prompt, "Do not call `run_sql` or `describe_table`")
  expect_no_match(prompt, "tagged A")
  expect_no_match(prompt, "tagged B")
})

test_that("the system prompt includes schema-qualified table labels", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA crm")
  DBI::dbExecute(con, "CREATE TABLE crm.sales (order_id VARCHAR, revenue DOUBLE)")

  agent <- commons(
    test_client(),
    data_sources = data_source(con, tables = "crm.sales")
  )

  expect_match(agent$get_system_prompt(), "- crm.sales", fixed = TRUE)
})

test_that("semantic_layer stores measures off the provider tool list", {
  agent <- test_agent(
    semantic_layer = semantic_layer(
      measure(
        "order_count",
        "Count of orders.",
        function() nrow(test_sales()),
        arguments = list()
      )
    )
  )

  provider_tools <- vapply(agent$get_tools(), tool_name, character(1))
  expect_false("order_count" %in% provider_tools)
})

test_that("commons() accepts an empty semantic layer", {
  agent <- test_agent(semantic_layer = semantic_layer())
  expect_s3_class(agent, "Commons")
})

test_that("commons() validates its inputs", {
  expect_snapshot(
    commons(client = "not a chat", data_sources = test_source()),
    error = TRUE
  )
  expect_snapshot(
    commons(client = test_client(), data_sources = "not a source"),
    error = TRUE
  )
  expect_snapshot(
    commons(
      client = test_client(),
      data_sources = test_source(),
      context_layer = "not context"
    ),
    error = TRUE
  )
  expect_snapshot(
    commons(
      client = test_client(),
      data_sources = test_source(),
      semantic_layer = list()
    ),
    error = TRUE
  )
  expect_snapshot(
    commons(client = test_client(), data_sources = test_source(), log = "yes"),
    error = TRUE
  )
  expect_snapshot(
    commons(
      client = test_client(),
      data_sources = test_source(),
      log = TRUE,
      share_with = 1
    ),
    error = TRUE
  )
})

test_that("SQL tools gain a source argument only with multiple sources", {
  single <- test_agent()
  expect_named(tool_properties(agent_tool(single, "run_sql")), "sql")
  expect_named(tool_properties(agent_tool(single, "describe_table")), "table")

  multi <- test_agent(
    data_sources = list(sales_db = test_source(), crm = test_source())
  )
  run_sql_props <- tool_properties(agent_tool(multi, "run_sql"))
  expect_named(run_sql_props, c("sql", "source"))
  expect_equal(type_values(run_sql_props$source), c("sales_db", "crm"))
  expect_named(
    tool_properties(agent_tool(multi, "describe_table")),
    c("table", "source")
  )
})

test_that("run_sql and describe_table route to the named source", {
  agent <- test_agent(
    data_sources = list(
      a = data_source(orders = data.frame(n = 1L)),
      b = data_source(orders = data.frame(n = 2L))
    )
  )

  run_sql <- agent_tool(agent, "run_sql")
  expect_match(run_sql("SELECT n FROM orders", source = "a")@value, "1")
  expect_match(run_sql("SELECT n FROM orders", source = "b")@value, "2")

  describe <- agent_tool(agent, "describe_table")
  res <- describe("orders", source = "b")
  expect_match(res@value, "integer")
  expect_match(S7::prop(res, "extra")$display$title, "(b)", fixed = TRUE)
})

test_that("the system prompt groups tables when there are several sources", {
  agent <- test_agent(
    data_sources = list(
      sales_db = test_source(),
      crm = data_source(accounts = data.frame(id = 1))
    )
  )
  prompt <- agent$get_system_prompt()

  expect_match(prompt, "## sales_db (duckdb)", fixed = TRUE)
  expect_match(prompt, "## crm (duckdb)", fixed = TRUE)
  expect_match(prompt, "- accounts", fixed = TRUE)
  expect_match(prompt, "Pass the source's name as `source`", fixed = TRUE)

  expect_no_match(test_agent()$get_system_prompt(), "## sales_db", fixed = TRUE)
})

test_that("a measure can take multiple sources' connections", {
  layer <- semantic_layer(
    measure(
      "compare_sources",
      "Compares the two databases.",
      function(a, b) NULL,
      arguments = list()
    )
  )
  agent <- test_agent(
    data_sources = list(a = test_source(), b = test_source()),
    semantic_layer = layer
  )

  expect_named(
    agent$.__enclos_env__$private$injections$compare_sources,
    c("a", "b")
  )
})

test_that("measures receive named data source connections by injection", {
  layer <- semantic_layer(
    measure(
      "region_revenue",
      "Total revenue for a region.",
      function(region, sales_db) {
        DBI::dbGetQuery(
          sales_db,
          sprintf(
            "SELECT SUM(revenue) AS revenue FROM sales WHERE region = %s",
            DBI::dbQuoteString(sales_db, region)
          )
        )
      },
      arguments = list(region = ellmer::type_string("The sales region."))
    )
  )
  agent <- test_agent(semantic_layer = layer)

  registry <- agent$.__enclos_env__$private$registry
  injections <- agent$.__enclos_env__$private$injections

  expect_named(injections$region_revenue, "sales_db")
  res <- call_measure_tool(
    registry,
    "region_revenue",
    '{"region": "EMEA"}',
    injections = injections
  )
  expect_match(res@value, "2450")
})

test_that("injection parameters are hidden from the model", {
  layer <- semantic_layer(
    measure(
      "region_revenue",
      "Total revenue for a region.",
      function(region, sales_db) NULL,
      arguments = list(region = ellmer::type_string("The sales region."))
    )
  )
  agent <- test_agent(semantic_layer = layer)
  registry <- agent$.__enclos_env__$private$registry

  expect_named(tool_properties(registry$region_revenue), "region")
  expect_no_match(
    search_measures_text(registry, "revenue for a region"),
    "sales_db"
  )
})

test_that("undocumented arguments matching no entry keep their defaults", {
  layer <- semantic_layer(
    measure(
      "order_count",
      "Count of orders.",
      function(sales_db, limit = 5L) limit,
      arguments = list()
    )
  )
  agent <- test_agent(semantic_layer = layer)

  injections <- agent$.__enclos_env__$private$injections
  expect_named(injections$order_count, "sales_db")

  res <- call_measure_tool(
    agent$.__enclos_env__$private$registry,
    "order_count",
    "{}",
    injections = injections
  )
  expect_match(res@value, "5")
})

test_that("an entry match wins over an undocumented argument's default", {
  layer <- semantic_layer(
    measure(
      "source_class",
      "Class of the source object.",
      function(sales_db = "unused default") class(sales_db)[[1]],
      arguments = list()
    )
  )
  agent <- test_agent(semantic_layer = layer)

  res <- call_measure_tool(
    agent$.__enclos_env__$private$registry,
    "source_class",
    "{}",
    injections = agent$.__enclos_env__$private$injections
  )
  expect_match(res@value, "duckdb_connection")
})

test_that("commons() errors on injection parameters matching no name", {
  layer <- semantic_layer(
    measure(
      "region_revenue",
      "Total revenue for a region.",
      function(region, warehouse) NULL,
      arguments = list(region = ellmer::type_string("The sales region."))
    )
  )

  expect_snapshot(
    commons(
      client = test_client(),
      data_sources = list(sales_db = test_source()),
      semantic_layer = layer
    ),
    error = TRUE
  )
  expect_snapshot(
    commons(
      client = test_client(),
      data_sources = test_source(),
      semantic_layer = layer
    ),
    error = TRUE
  )
})


test_that("prewarm() builds the context store ahead of the first search", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# Revenue", "", "Revenue means booked revenue."), path)
  layer <- context_layer(files = path)

  # test_source() has no dictionary, so the agent augments nothing and shares
  # `layer`'s cache environment.
  agent <- test_agent(context_layer = layer)
  expect_null(layer$cache$store)

  agent$prewarm()
  expect_false(is.null(layer$cache$store))
  expect_match(context_search(layer, "revenue")[[1]], "booked")
})

test_that("prewarm() without a context layer is a no-op", {
  expect_no_error(test_agent()$prewarm())
})

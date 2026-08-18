local_dict_path <- function(env = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".yaml", .local_envir = env)
  writeLines(
    c(
      '$version: "0.1.0"',
      "name: retail sales",
      "description: Order and revenue data for a small retailer.",
      "details: Revenue figures exclude tax.",
      "tables:",
      "  - name: sales",
      "    description: One row per order line.",
      "    details: Cancelled orders are excluded.",
      "    columns:",
      "      - name: order_id",
      "        type: number(id)",
      "        constraints: [primary_key]",
      "        description: Unique order identifier.",
      "      - name: revenue",
      "        type: number(quantity)",
      "        units: USD",
      "        range: [0, 10000]",
      "      - name: region",
      "        type: enum",
      "        values: [Americas, APAC, EMEA]",
      "      - name: booked_at",
      "        type: date",
      "        description: Date the order was booked.",
      "relationships:",
      "  - join: sales.rep = reps.name",
      "    cardinality: many-to-one",
      "    description: Each sale is credited to one rep.",
      "glossary:",
      "  AOV: Average order value.",
      "  booked: An order is booked once payment clears."
    ),
    path
  )
  path
}

local_dict_source <- function(env = parent.frame()) {
  data_source(sales = test_sales(), dictionary = local_dict_path(env))
}

catalog_test_columns <- function() {
  data.frame(
    column = c("AMOUNT", "ORDER_ID"),
    type = c("NUMBER(38,2)", "NUMBER(38,0)"),
    nullable = c(TRUE, FALSE),
    description = c("Warehouse amount description.", "Warehouse key."),
    row.names = NULL
  )
}

test_that("data_dictionary() reads and keys tables and columns", {
  skip_if_not_installed("yaml")
  dict <- data_dictionary(local_dict_path())

  expect_s3_class(dict, "commons_data_dictionary")
  expect_equal(dict$name, "retail sales")
  expect_named(dict$tables, "sales")
  expect_named(
    dict$tables$sales$columns,
    c("order_id", "revenue", "region", "booked_at")
  )
  expect_equal(dict$tables$sales$columns$revenue$units, "USD")
  expect_named(dict$glossary, c("AOV", "booked"))
  expect_length(dict$relationships, 1)
})

test_that("pre-keyed maps of tables and columns are accepted", {
  dict <- new_data_dictionary(list(
    tables = list(
      sales = list(
        description = "One row per order.",
        columns = list(revenue = list(units = "USD"))
      )
    )
  ))

  expect_named(dict$tables, "sales")
  expect_equal(dict$tables$sales$columns$revenue$units, "USD")
})

test_that("tables and columns without names error", {
  expect_snapshot(
    new_data_dictionary(list(tables = list(list(description = "no name")))),
    error = TRUE
  )
  expect_snapshot(
    new_data_dictionary(list(
      tables = list(list(name = "sales", columns = list(list(type = "date"))))
    )),
    error = TRUE
  )
})

test_that("unknown fields and missing sections are tolerated", {
  dict <- new_data_dictionary(list(`$version` = "0.1.0", frobnicate = 1))

  expect_equal(dict$tables, list())
  expect_length(dict$glossary, 0)
  expect_length(dict$relationships, 0)
  expect_null(dict$description)
})

test_that("data_source() accepts a dictionary path", {
  skip_if_not_installed("yaml")
  src <- data_source(sales = test_sales(), dictionary = local_dict_path())
  expect_s3_class(src$dictionary, "commons_data_dictionary")
})

test_that("data_source() rejects other dictionary inputs", {
  expect_snapshot(
    data_source(sales = test_sales(), dictionary = 42),
    error = TRUE
  )
})

test_that("dictionary content lands in the system prompt", {
  skip_if_not_installed("yaml")
  src <- local_dict_source()
  prompt <- commons_system_prompt(list(src))

  expect_match(prompt, "# About the data", fixed = TRUE)
  expect_match(prompt, "- sales", fixed = TRUE)
  expect_match(prompt, "Revenue figures exclude tax", fixed = TRUE)
  expect_match(prompt, "AOV: Average order value", fixed = TRUE)
  expect_no_match(prompt, "One row per order line", fixed = TRUE)
})

test_that("multi-source prompts label dictionary blocks by source", {
  skip_if_not_installed("yaml")
  sources <- list(
    sales_db = local_dict_source(),
    crm = data_source(accounts = data.frame(id = 1))
  )
  prompt <- commons_system_prompt(sources)

  expect_match(prompt, "## sales_db", fixed = TRUE)
  expect_match(prompt, "Revenue figures exclude tax", fixed = TRUE)
  expect_match(prompt, "Definitions of domain terms", fixed = TRUE)
})

test_that("sources without dictionaries leave the prompt unchanged", {
  expect_equal(dictionary_context_text(list(test_source())), "")
  expect_equal(glossary_context_text(list(test_source())), "")
})

test_that("glossary entries past the cap are co-resolved at first touch", {
  dict <- new_data_dictionary(list(
    tables = list(list(
      name = "sales",
      description = "Sales with AOV and churn columns."
    )),
    glossary = list(AOV = strrep("x", 3990), churn = "A lapsed customer.")
  ))

  expect_equal(glossary_ambient(dict), "AOV")

  entry <- dictionary_entry_text(dict, "sales")
  expect_match(entry, "churn: A lapsed customer", fixed = TRUE)
  expect_no_match(entry, "AOV: x", fixed = TRUE)
})

test_that("describe_table merges the dictionary with the live schema", {
  skip_if_not_installed("yaml")
  res <- describe_table_tool(local_dict_source(), "sales")

  expect_match(res@value, "One row per order line", fixed = TRUE)
  expect_match(
    res@value,
    "- order_id (number(id), primary_key): Unique order identifier.",
    fixed = TRUE
  )
  expect_match(res@value, "- product_line (character)", fixed = TRUE)
  expect_match(res@value, "not present in the table: booked_at", fixed = TRUE)
  expect_match(res@value, "sales.rep = reps.name (many-to-one)", fixed = TRUE)
  expect_match(res@value, "Sample summary", fixed = TRUE)
})

test_that("warehouse metadata supplements an authored dictionary", {
  relations <- list(
    "ANALYTICS.PUBLIC.ORDERS" = list(
      id = DBI::Id(
        catalog = "ANALYTICS",
        schema = "PUBLIC",
        table = "ORDERS"
      ),
      kind = "table",
      description = "Warehouse table description."
    )
  )
  dictionary <- new_data_dictionary(list(
    tables = list(
      orders = list(
        description = "Authored table description.",
        columns = list(
          amount = list(
            type = "number(quantity)",
            units = "USD",
            description = "Authored column description."
          ),
          missing = list(description = "Not in the warehouse.")
        )
      ),
      unselected = list(description = "Not selected.")
    ),
    relationships = list(
      list(join = "orders.order_id = unselected.order_id"),
      list(join = "orders.order_id = external.order_id")
    )
  ))

  merged <- catalog_merge_dictionary(
    dictionary,
    relations,
    NULL,
    function(...) catalog_test_columns(),
    "upper"
  )
  table <- merged$dictionary$tables[["ANALYTICS.PUBLIC.ORDERS"]]

  expect_named(merged$dictionary$tables, "ANALYTICS.PUBLIC.ORDERS")
  expect_equal(table$description, "Authored table description.")
  expect_equal(table$kind, "table")
  expect_named(table$columns, c("AMOUNT", "ORDER_ID", "missing"))
  expect_equal(table$columns$AMOUNT$type, "NUMBER(38,2)")
  expect_true(table$columns$AMOUNT$nullable)
  expect_equal(table$columns$AMOUNT$units, "USD")
  expect_equal(
    table$columns$AMOUNT$description,
    "Authored column description."
  )
  expect_equal(table$columns$ORDER_ID$description, "Warehouse key.")
  rendered <- dictionary_columns_text(table$columns, catalog_test_columns())
  expect_match(rendered, "AMOUNT (NUMBER(38,2), nullable, USD)", fixed = TRUE)
  expect_no_match(rendered, "Warehouse amount description.", fixed = TRUE)
  expect_equal(
    merged$relations[["ANALYTICS.PUBLIC.ORDERS"]]$columns,
    catalog_test_columns()
  )
  expect_equal(
    merged$definition_bindings$tables,
    c(orders = "ANALYTICS.PUBLIC.ORDERS", unselected = NA_character_)
  )
  expect_equal(
    merged$definition_bindings$columns$orders,
    c(amount = "AMOUNT", missing = NA_character_)
  )
  expect_true(merged$definition_bindings$strict)
  expect_length(merged$dictionary$relationships, 1L)
  entry <- dictionary_entry_text(
    merged$dictionary,
    "ANALYTICS.PUBLIC.ORDERS"
  )
  expect_match(entry, "external.order_id", fixed = TRUE)
  expect_no_match(entry, "unselected.order_id", fixed = TRUE)
  sql_entry <- dictionary_sql_entries(
    list(dictionary = merged$dictionary),
    "SELECT * FROM orders",
    NULL,
    NULL
  )
  expect_match(sql_entry, "Authored table description.", fixed = TRUE)
})

test_that("fully qualified authored names match before relative names", {
  relations <- list(
    "ANALYTICS.PUBLIC.ORDERS" = list(
      id = DBI::Id(
        catalog = "ANALYTICS",
        schema = "PUBLIC",
        table = "ORDERS"
      ),
      kind = "table",
      description = NULL
    ),
    "ANALYTICS.STAGING.ORDERS" = list(
      id = DBI::Id(
        catalog = "ANALYTICS",
        schema = "STAGING",
        table = "ORDERS"
      ),
      kind = "table",
      description = NULL
    )
  )
  dictionary <- new_data_dictionary(list(
    tables = list(
      "analytics.public.orders" = list(description = "Public orders.")
    )
  ))
  merged <- catalog_merge_dictionary(
    dictionary,
    relations,
    NULL,
    function(...) catalog_test_columns()[1, ],
    "upper"
  )

  expect_named(merged$dictionary$tables, "ANALYTICS.PUBLIC.ORDERS")
})

test_that("relative authored table names must be unambiguous", {
  relations <- lapply(c("PUBLIC", "STAGING"), function(schema) {
    list(
      id = DBI::Id(
        catalog = "ANALYTICS",
        schema = schema,
        table = "ORDERS"
      ),
      kind = "table",
      description = NULL
    )
  })
  names(relations) <- c(
    "ANALYTICS.PUBLIC.ORDERS",
    "ANALYTICS.STAGING.ORDERS"
  )
  dictionary <- new_data_dictionary(list(
    tables = list(orders = list(description = "Orders."))
  ))

  expect_snapshot(
    catalog_merge_dictionary(
      dictionary,
      relations,
      NULL,
      function(...) NULL,
      "upper"
    ),
    error = TRUE
  )
})

test_that("discovered columns cannot shadow governed definitions", {
  relations <- list(
    "ANALYTICS.PUBLIC.ORDERS" = list(
      id = DBI::Id(
        catalog = "ANALYTICS",
        schema = "PUBLIC",
        table = "ORDERS"
      ),
      kind = "table",
      description = NULL
    )
  )
  dictionary <- new_data_dictionary(list(
    tables = list(orders = list(definitions = list(
      order_id = list(expr = "ORDER_ID", type = "number")
    )))
  ))

  expect_snapshot(
    catalog_merge_dictionary(
      dictionary,
      relations,
      NULL,
      function(...) catalog_test_columns(),
      "upper"
    ),
    error = TRUE
  )
})

test_that("a SQL query delivers a table's entry once", {
  skip_if_not_installed("yaml")
  src <- local_dict_source()
  tracker <- new.env(parent = emptyenv())

  first <- run_sql_tool(src, "SELECT count(*) FROM sales", tracker = tracker)
  expect_match(first@value, "Dictionary entry for `sales`", fixed = TRUE)
  expect_match(first@value, "Documented columns", fixed = TRUE)

  again <- run_sql_tool(src, "SELECT count(*) FROM sales", tracker = tracker)
  expect_no_match(again@value, "Dictionary entry", fixed = TRUE)
})

test_that("describing a table forestalls the SQL-side delivery", {
  skip_if_not_installed("yaml")
  src <- local_dict_source()
  tracker <- new.env(parent = emptyenv())

  describe_table_tool(src, "sales", tracker = tracker)
  res <- run_sql_tool(src, "SELECT count(*) FROM sales", tracker = tracker)

  expect_no_match(res@value, "Dictionary entry", fixed = TRUE)
})

test_that("first-touch state is keyed by source", {
  skip_if_not_installed("yaml")
  tracker <- new.env(parent = emptyenv())

  first <- run_sql_tool(
    local_dict_source(),
    "SELECT count(*) FROM sales",
    source_name = "a",
    tracker = tracker
  )
  other <- run_sql_tool(
    local_dict_source(),
    "SELECT count(*) FROM sales",
    source_name = "b",
    tracker = tracker
  )

  expect_match(first@value, "Dictionary entry", fixed = TRUE)
  expect_match(other@value, "Dictionary entry", fixed = TRUE)
})

test_that("queries that touch no documented table append nothing", {
  skip_if_not_installed("yaml")
  src <- local_dict_source()

  expect_no_match(
    run_sql_tool(src, "SELECT 1 AS one")@value,
    "Dictionary entry",
    fixed = TRUE
  )
  expect_no_match(
    run_sql_tool(test_source(), "SELECT count(*) FROM sales")@value,
    "Dictionary entry",
    fixed = TRUE
  )
})

test_that("dictionary prose is searchable via the context layer", {
  skip_if_not_installed("yaml")
  layer <- augment_context_layer(NULL, list(local_dict_source()))

  hits <- context_search(layer, "average order value")
  expect_match(paste(hits, collapse = "\n"), "AOV", fixed = TRUE)

  column_hits <- context_search(layer, "unique order identifier")
  expect_no_match(
    paste(column_hits, collapse = "\n"),
    "Unique order identifier",
    fixed = TRUE
  )
})

test_that("augmenting keeps existing context docs", {
  skip_if_not_installed("yaml")
  path <- withr::local_tempfile(fileext = ".md")
  writeLines("Booked revenue excludes tax.", path)
  layer <- context_layer(files = path)
  augmented <- augment_context_layer(layer, list(local_dict_source()))

  expect_true("Booked revenue excludes tax." %in% augmented$docs)
  expect_gt(length(augmented$docs), length(layer$docs))
})

test_that("augmenting without dictionaries is a no-op", {
  expect_null(augment_context_layer(NULL, list(test_source())))
})

test_that("agent tools share first-touch state", {
  skip_if_not_installed("yaml")
  agent <- test_agent(
    data_sources = list(
      sales_db = data_source(
        sales = test_sales(),
        dictionary = local_dict_path()
      )
    )
  )

  describe <- agent_tool(agent, "describe_table")
  run_sql <- agent_tool(agent, "run_sql")

  expect_match(describe("sales")@value, "One row per order line", fixed = TRUE)
  expect_no_match(
    run_sql("SELECT count(*) AS n FROM sales")@value,
    "Dictionary entry",
    fixed = TRUE
  )
})

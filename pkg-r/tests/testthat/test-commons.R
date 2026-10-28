test_that("commons() runs measures", {
  tr <- commons(
    data_sources = list(sales_db = test_source()),
    semantic_layer = semantic_layer(count_measure_tool())
  )

  expect_equal(tr$measure("order_count", arguments = list(region = "EMEA")), 3)
})

test_that("$run_sql() expands governed definitions", {
  tr <- commons(data_sources = list(sales_db = definitions_source()))
  plain <- tr$run_sql("SELECT COUNT(*) AS n FROM sales WHERE region = 'EMEA'")
  expect_equal(plain$n, sum(test_sales()$region == "EMEA"))

  expect_equal(
    tr$run_sql("SELECT COUNT(*) AS n FROM sales WHERE {{emea}}"),
    plain
  )
  expect_equal(
    tr$run_sql("SELECT COUNT(*) AS n FROM sales WHERE {{sales::emea}}"),
    plain
  )
  expect_equal(
    tr$run_sql("SELECT {{big_revenue}} AS value FROM sales")$value,
    tr$metrics("big_revenue")$big_revenue
  )
  expect_snapshot(error = TRUE, {
    tr$run_sql("SELECT COUNT(*) FROM sales WHERE {{not_a_definition}}")
    tr$run_sql("DELETE FROM sales")
  })
})

test_that("$run_sql() loads pending pins", {
  skip_if_not_installed("pins")
  sales <- test_sales()
  tr <- commons(
    data_sources = data_source(
      board_with_pins(sales = sales, orders = sales[1:2, ]),
      tables = c(sales = "sales", orders = "orders")
    )
  )

  expect_equal(tr$run_sql("SELECT * FROM sales"), sales)
  expect_equal(tr$run_sql("SELECT * FROM orders"), sales[1:2, ])
})

test_that("agent() builds an agent around a commons() object", {
  withr::local_options(commons.allow_unsafe_fallback = TRUE)
  tr <- commons(data_sources = list(sales_db = test_source()))

  agent <- agent(test_client(), commons = tr)
  expect_identical(agent$commons, tr)
  expect_s3_class(test_agent()$commons, "commons")
})

test_that("commons() requires named arguments", {
  expect_snapshot(commons(test_source()), error = TRUE)
  expect_snapshot(commons(), error = TRUE)
})

test_that("commons() validates its inputs", {
  expect_snapshot(commons(data_sources = "not a source"), error = TRUE)
  expect_snapshot(
    commons(data_sources = test_source(), context_layer = "not context"),
    error = TRUE
  )
  expect_snapshot(
    commons(data_sources = test_source(), semantic_layer = list()),
    error = TRUE
  )
})

test_that("commons() errors on injection parameters matching no name", {
  withr::local_options(commons.allow_unsafe_fallback = TRUE)
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
      data_sources = list(sales_db = test_source()),
      semantic_layer = layer
    ),
    error = TRUE
  )
  expect_snapshot(
    commons(data_sources = test_source(), semantic_layer = layer),
    error = TRUE
  )
})

test_that("commons() still builds an agent when called the old way", {
  withr::local_options(
    commons.allow_unsafe_fallback = TRUE,
    lifecycle_verbosity = "warning"
  )
  layer <- semantic_layer(count_measure_tool())

  expect_snapshot(
    old <- commons(
      test_client(),
      list(sales_db = test_source()),
      layer,
      mode = "trusted only"
    )
  )
  expect_s3_class(old, "Commons")
  expect_s3_class(old$commons, "commons")
  tools <- vapply(old$get_tools(), tool_name, character(1))
  expect_true("call_measure" %in% tools)
  expect_false("run_sql" %in% tools)

  named <- suppressWarnings(commons(
    client = test_client(),
    data_sources = list(sales_db = test_source())
  ))
  expect_s3_class(named, "Commons")
  expect_snapshot(
    commons(client = "not a chat", data_sources = test_source()),
    error = TRUE
  )
  expect_snapshot(
    commons(test_client(), test_source(), NULL, NULL, "prompt"),
    error = TRUE
  )
})

test_that("$search() names the commons object's methods", {
  tr <- commons(
    data_sources = list(sales_db = definitions_source()),
    semantic_layer = semantic_layer(count_measure_tool())
  )

  expect_snapshot(tr$search("big revenue region orders"))
})

test_that("$metrics() accepts `where` as a string or unnamed triples", {
  tr <- commons(data_sources = list(sales_db = definitions_source()))
  emea <- tr$metrics("big_revenue", where = list(
    list(column = "region", op = "=", value = "EMEA"),
    list(column = "revenue", op = ">", value = 0)
  ))

  expect_equal(
    tr$metrics("big_revenue", where = "region = 'EMEA' and revenue > 0"),
    emea
  )
  expect_equal(
    tr$metrics(
      "big_revenue",
      where = list(c("region", "=", "EMEA"), list("revenue", ">", 0))
    ),
    emea
  )
  expect_equal(
    tr$metrics("big_revenue", where = c("region", "=", "EMEA")),
    tr$metrics("big_revenue", where = "region = 'EMEA'")
  )
  expect_equal(
    as_where_triples("name <> 'O''Brien'")[[1]],
    list(column = "name", op = "!=", value = "O'Brien", quoted = TRUE)
  )
  expect_snapshot(error = TRUE, {
    tr$metrics("big_revenue", where = "region IN ('EMEA', 'APAC')")
    tr$metrics("big_revenue", where = list(c("region", "EMEA")))
  })
})

test_that("`where` strings reject malformed conditions", {
  expect_equal(
    as_where_triples("\"region\" = 'EMEA' AND revenue > 0"),
    as_where_triples("region = 'EMEA' AND revenue > 0")
  )
  expect_error(as_where_triples("a = 1 AND "), class = "rlang_error")
  expect_error(as_where_triples("a = 1AND b = 2"), class = "rlang_error")
  expect_error(as_where_triples("\"a = 1"), class = "rlang_error")
  expect_error(as_where_triples("a\" = 1"), class = "rlang_error")
})

test_that("missing calculations and metrics don't list empty alternatives", {
  tr <- commons(data_sources = list(sales_db = test_source()))

  expect_snapshot(error = TRUE, {
    tr$calculation("nope")
    tr$metrics("nope")
  })
})

test_that("$metrics() preserves quoted numeric strings in where", {
  sales <- data.frame(region = c("001", "1"), revenue = c(10, 20))
  tr <- commons(
    data_sources = data_source(
      sales = sales,
      dictionary = local_definitions_dict(c(
        "      - name: n_orders",
        "        expr: ROW_COUNT()"
      ))
    )
  )

  expect_equal(tr$metrics("n_orders", where = "region = '001'")$n_orders, 1)
  expect_equal(tr$metrics("n_orders", where = "region = '1'")$n_orders, 1)
  expect_equal(tr$metrics("n_orders", where = "region = 1")$n_orders, 2)
})

test_that("parsed where literals retain quoting for native semantic metrics", {
  source <- test_semantic_source()
  members <- registry_semantic_members(semantic_models_registry(list(
    db = source
  )))
  con <- data_source_state(source)$con

  expect_equal(
    semantic_where_conditions(
      as_where_triples("region = '001' AND region <> 1"),
      members,
      con,
      member_references = function(dimension, con) "region"
    ),
    c("(region = '001')", "(region != 1)")
  )
})

test_that("commons() prints its contents and method signatures", {
  tr <- commons(
    data_sources = list(sales_db = definitions_source()),
    semantic_layer = semantic_layer(count_measure_tool())
  )

  expect_snapshot(tr)
})

test_that("commons() lists only the calculation methods it can run", {
  expect_snapshot(commons(data_sources = list(sales_db = test_source())))
})

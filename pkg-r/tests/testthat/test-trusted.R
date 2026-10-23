test_that("trusted() runs measures", {
  tr <- trusted(
    data_sources = list(sales_db = test_source()),
    semantic_layer = semantic_layer(count_measure_tool())
  )

  expect_equal(tr$measure("order_count", arguments = list(region = "EMEA")), 3)
})

test_that("commons() builds an agent around a trusted() object", {
  withr::local_options(commons.allow_unsafe_fallback = TRUE)
  tr <- trusted(list(sales_db = test_source()))

  agent <- commons(test_client(), tr)
  expect_identical(agent$trusted, tr)
  expect_s3_class(test_agent()$trusted, "commons_trusted")
  expect_snapshot(
    commons(test_client(), tr, semantic_layer = semantic_layer()),
    error = TRUE
  )
})

test_that("$search() names the trusted object's methods", {
  tr <- trusted(
    data_sources = list(sales_db = definitions_source()),
    semantic_layer = semantic_layer(count_measure_tool())
  )

  expect_snapshot(tr$search("big revenue region orders"))
})

test_that("$metrics() accepts `where` as a string or unnamed triples", {
  tr <- trusted(list(sales_db = definitions_source()))
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
    list(column = "name", op = "!=", value = "O'Brien")
  )
  expect_snapshot(error = TRUE, {
    tr$metrics("big_revenue", where = "region IN ('EMEA', 'APAC')")
    tr$metrics("big_revenue", where = list(c("region", "EMEA")))
  })
})

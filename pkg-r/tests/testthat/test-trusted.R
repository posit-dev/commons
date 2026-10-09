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

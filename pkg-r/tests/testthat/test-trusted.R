test_that("trusted() runs measures and records the call", {
  tr <- trusted(
    list(sales_db = test_source()),
    semantic_layer = semantic_layer(count_measure_tool())
  )

  n <- tr$measure("order_count", arguments = list(region = "EMEA"))
  expect_equal(unclass(n)[[1]], 3)
  expect_equal(
    attr(n, "commons_trusted_call"),
    list(kind = "measure", name = "order_count", arguments = list(region = "EMEA"))
  )
  expect_snapshot(print(n))
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

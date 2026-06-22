test_that("derive_tag reports how the answer was produced", {
  expect_equal(derive_tag(c("search_measures", "call_measure")), "A")
  expect_equal(derive_tag(c("call_measure", "run_sql")), "B")
  expect_equal(derive_tag("run_sql"), "B")
  expect_true(is.na(derive_tag(character())))
  expect_true(is.na(derive_tag("search_context")))
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
  expect_true(is.na(agent$last_tag))
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
    commons(client = "not a chat", data_source = test_source()),
    error = TRUE
  )
  expect_snapshot(
    commons(client = test_client(), data_source = "not a source"),
    error = TRUE
  )
  expect_snapshot(
    commons(
      client = test_client(),
      data_source = test_source(),
      context_layer = "not context"
    ),
    error = TRUE
  )
  expect_snapshot(
    commons(
      client = test_client(),
      data_source = test_source(),
      semantic_layer = list()
    ),
    error = TRUE
  )
})

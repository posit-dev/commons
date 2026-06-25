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
    data_source = data_source(con, tables = "crm.sales")
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

test_that("default log directory can come from COMMONS_LOG_DIR", {
  withr::local_envvar(COMMONS_LOG_DIR = NA)
  expect_equal(commons_log_dir(), file.path(tempdir(), "commons-logs"))

  path <- withr::local_tempdir()
  withr::local_envvar(COMMONS_LOG_DIR = path)
  expect_equal(commons_log_dir(), path)
})

test_that("local trajectory logs are replayed when read", {
  path <- withr::local_tempdir()
  chat <- test_client()
  chat$add_turn(
    ellmer::UserTurn("How many orders are there?"),
    ellmer::AssistantTurn("There are 6 orders."),
    log_tokens = FALSE
  )

  logger <- new_trajectory_logger(path)
  record_trajectory(logger, chat)

  logs <- read_trajectories(path)
  expect_length(logs, 1)
  expect_null(names(logs[[1]]))
  expect_s7_class(logs[[1]][[1]], ellmer::UserTurn)
  expect_s7_class(logs[[1]][[2]], ellmer::AssistantTurn)

  replay <- test_client()
  expect_no_error(replay$set_turns(logs[[1]]))
  expect_equal(
    replay$get_turns(include_system_prompt = TRUE),
    logs[[1]]
  )
})

test_that("trajectory recording does not return the local log path", {
  path <- withr::local_tempdir()
  chat <- test_client()
  chat$add_turn(
    ellmer::UserTurn("How many orders are there?"),
    ellmer::AssistantTurn("There are 6 orders."),
    log_tokens = FALSE
  )

  logger <- new_trajectory_logger(path)
  expect_null(record_trajectory(logger, chat))
})

test_that("logged Claude streams do not append the local trajectory path", {
  skip_if_not_installed("promises")
  skip_if_not_installed("later")
  skip_if(
    !nzchar(Sys.getenv("ANTHROPIC_API_KEY")),
    "ANTHROPIC_API_KEY is not available."
  )

  path <- withr::local_tempdir()
  agent <- commons(
    client = ellmer::chat_claude(
      params = ellmer::params(temperature = 0, max_tokens = 32),
      cache = "none"
    ),
    data_source = test_source(),
    log = path
  )

  chunks <- tryCatch(
    sync_promise(coro::async_collect(agent$stream_async("Reply with only: ok"))),
    error = function(err) {
      skip(sprintf(
        "ANTHROPIC_API_KEY is not functional: %s",
        conditionMessage(err)
      ))
    }
  )

  expect_true(all(vapply(chunks, is.character, logical(1))))
  expect_false(any(grepl("commons-trajectory", unlist(chunks), fixed = TRUE)))
  expect_length(
    list.files(path, pattern = "^commons-trajectory-.*[.]rds$"),
    1
  )
})

test_that("trajectory pins can be read from a board", {
  skip_if_not_installed("pins")

  board <- pins::board_temp()
  chat <- test_client()
  chat$add_turn(
    ellmer::UserTurn("How many orders are there?"),
    ellmer::AssistantTurn("There are 6 orders."),
    log_tokens = FALSE
  )

  trajectory <- update_trajectory(
    init_trajectory("test-conversation"),
    chat
  )
  suppressMessages(
    pins::pin_write(
      board,
      trajectory,
      name = "commons-trajectory-test-conversation",
      type = "rds"
    )
  )
  suppressMessages(
    pins::pin_write(board, list(x = 1), name = "not-a-trajectory", type = "rds")
  )

  logs <- read_trajectories(board)
  expect_length(logs, 1)
  expect_null(names(logs[[1]]))
  expect_s7_class(logs[[1]][[1]], ellmer::UserTurn)
  expect_s7_class(logs[[1]][[2]], ellmer::AssistantTurn)

  replay <- test_client()
  expect_no_error(replay$set_turns(logs[[1]]))
  expect_equal(
    replay$get_turns(include_system_prompt = TRUE),
    logs[[1]]
  )
})

test_that("Connect trajectory pins request ACL access", {
  skip_if_not_installed("pins")

  board <- pins::board_temp()
  trajectory <- init_trajectory("test-conversation")

  args <- pin_trajectory_write_args(board, "test-pin", trajectory)
  expect_null(args$access_type)

  class(board) <- c("pins_board_connect", class(board))
  args <- pin_trajectory_write_args(board, "test-pin", trajectory)
  expect_equal(args$access_type, "acl")
})

test_that("trajectory pin names fit Connect content name limits", {
  withr::local_envvar(
    CONNECT_CONTENT_GUID = "ea3c1445-cb71-42df-a2f2-bdb18874ef41"
  )

  name <- trajectory_pin_name("20260624t124240-123-abcdefghij")

  expect_lte(nchar(name), 64)
  expect_match(name, "^[a-z0-9._-]+$")
  expect_match(name, "^commons-trajectory-ea3c1445-")
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

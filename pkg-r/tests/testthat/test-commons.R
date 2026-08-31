test_that("commons() registers only the tools the agent's composition earns", {
  agent <- test_agent()

  expect_s3_class(agent, "Chat")
  # No measures: nothing about the agent's surface should imply them.
  expect_setequal(
    vapply(agent$get_tools(), tool_name, character(1)),
    c("search_context", "describe_table", "run_sql", "run_r")
  )
  expect_no_match(agent$get_system_prompt(), "search_pool")

  with_measures <- test_agent(
    semantic_layer = semantic_layer(count_measure_tool())
  )
  expect_setequal(
    vapply(with_measures$get_tools(), tool_name, character(1)),
    c(
      "search_pool",
      "call_measure",
      "search_context",
      "describe_table",
      "run_sql",
      "run_r"
    )
  )
})

test_that("ellmer chat initialization supports both model APIs", {
  client <- list(get_provider = function() "provider")

  expect_equal(
    ellmer_chat_initialize_args(client),
    list(provider = "provider", echo = "none")
  )

  client$get_model_object <- function() "model"
  expect_equal(
    ellmer_chat_initialize_args(client),
    list(provider = "provider", model = "model", echo = "none")
  )
})

test_that("commons() configures run_r network access", {
  restricted <- agent_tool(test_agent(), "run_r")
  full <- agent_tool(test_agent(network = "full"), "run_r")

  expect_match(tool_description(restricted), "no network access")
  expect_no_match(tool_description(full), "network access")
  expect_false(S7::prop(restricted, "annotations")$open_world_hint)
  expect_true(S7::prop(full, "annotations")$open_world_hint)
})

test_that("run_r describes both protection modes as sandboxed", {
  sandboxed <- Commons$new(
    client = test_client(),
    data_sources = list(sales_db = test_source()),
    protection = "sandbox"
  )
  guarded <- Commons$new(
    client = test_client(),
    data_sources = list(sales_db = test_source()),
    protection = "guardrails"
  )
  sandboxed_description <- tool_description(agent_tool(sandboxed, "run_r"))
  guarded_description <- tool_description(agent_tool(guarded, "run_r"))

  expect_identical(guarded_description, sandboxed_description)
})

test_that("search_context uses a completed title without a context layer", {
  result <- agent_tool(test_agent(), "search_context")("anything")

  expect_equal(result@extra$display$title, "Searched context")
})

test_that("the system prompt includes tables and the date", {
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
  prompt <- agent$get_system_prompt()

  expect_match(prompt, "sales")
  expect_no_match(prompt, "order_count")
  expect_match(prompt, format(Sys.Date(), "%Y-%m-%d"), fixed = TRUE)
})

test_that("instructions are appended to the packaged system prompt", {
  instructions <- "Use the organization's fiscal-year conventions."
  agent <- test_agent(instructions = instructions)
  prompt <- agent$get_system_prompt()

  expect_match(
    prompt,
    paste("## Additional instructions", instructions, sep = "\n\n"),
    fixed = TRUE
  )
  expect_true(endsWith(prompt, instructions))
})

test_that("instructions can be read from a file", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines("Prefer fiscal-year comparisons.", path)
  prompt <- test_agent(instructions = path)$get_system_prompt()

  expect_true(endsWith(prompt, "Prefer fiscal-year comparisons."))
})

test_that("a system prompt already set on the client warns", {
  client <- test_client()
  client$set_system_prompt("You are a pirate.")

  expect_warning(
    commons(client, data_sources = list(sales_db = test_source())),
    "commons builds its own"
  )
})

test_that("instructions are validated", {
  expect_error(
    test_agent(instructions = c("a", "b")),
    "single string"
  )

  expect_error(
    test_agent(instructions = "missing-instructions.md"),
    "does not exist"
  )
})

test_that("the system prompt includes schema-qualified table labels", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA crm")
  DBI::dbExecute(
    con,
    "CREATE TABLE crm.sales (order_id VARCHAR, revenue DOUBLE)"
  )

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
  expect_s3_class(agent, "Chat")
})

test_that("commons() validates its inputs", {
  expect_error(test_agent(network = "partial"), "network")
  expect_error(
    commons(test_client(), test_source(), NULL, NULL, "prompt"),
    "must be empty"
  )
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
})

test_that("run_sql delivers one citation reminder per user turn", {
  agent <- test_agent()
  run_sql <- agent_tool(agent, "run_sql")

  first <- run_sql("SELECT count(*) AS n FROM sales")
  second <- run_sql("SELECT count(*) AS n FROM sales")

  expect_match(first@value, "<commons-citation>", fixed = TRUE)
  expect_no_match(second@value, "<commons-citation>", fixed = TRUE)
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
    search_pool_text(registry, empty_definitions(), "revenue for a region"),
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
  # `layer`'s store.
  agent <- test_agent(context_layer = layer)
  expect_null(context_layer_state(layer)$store)

  agent$prewarm()
  expect_false(is.null(context_layer_state(layer)$store))
  expect_match(context_search(layer, "revenue")[[1]], "booked")
})

test_that("prewarm() without a context layer is a no-op", {
  expect_no_error(test_agent()$prewarm())
})

test_that("prewarm() records a cache-miss build and its own span", {
  skip_if_not_installed("otelsdk")

  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# Revenue", "", "Revenue means booked revenue."), path)
  agent <- test_agent(context_layer = context_layer(files = path))

  recorded <- otelsdk::with_otel_record(agent$prewarm())
  names <- vapply(recorded$traces, `[[`, character(1), "name")
  expect_true("commons_context_store_build" %in% names)

  build_span <- recorded$traces[[which(names == "commons_context_store_build")]]
  expect_equal(build_span$attributes[["commons.context.n_docs"]], 1L)

  prewarm_span <- recorded$traces[[which(names == "commons_context_prewarm")]]
  expect_equal(prewarm_span$attributes[["commons.context.n_docs"]], 1L)
  expect_equal(prewarm_span$attributes[["commons.context.cache_hit"]], FALSE)
})

test_that("prewarm() records a cache hit without a build span", {
  skip_if_not_installed("otelsdk")

  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# Revenue", "", "Revenue means booked revenue."), path)
  agent <- test_agent(context_layer = context_layer(files = path))
  agent$prewarm()

  recorded <- otelsdk::with_otel_record(agent$prewarm())
  names <- vapply(recorded$traces, `[[`, character(1), "name")
  expect_false("commons_context_store_build" %in% names)

  prewarm_span <- recorded$traces[[which(names == "commons_context_prewarm")]]
  expect_equal(prewarm_span$attributes[["commons.context.cache_hit"]], TRUE)
})

test_that("prewarm() warms board pins in the background without loading them", {
  skip_if_not_installed("pins")

  board <- board_with_pins(
    "team-orders" = data.frame(id = 1:3),
    "team-reps" = data.frame(rep = c("Ada", "Bo"))
  )
  src <- data_source(
    board,
    tables = c(orders = "team-orders", reps = "team-reps")
  )
  agent <- test_agent(data_sources = list(sales_db = src))

  expect_length(DBI::dbListTables(data_source_state(src)$con), 0)

  agent$prewarm()
  p <- data_source_state(src)$pending$process
  expect_s3_class(p, "r_process")
  withr::defer(p$kill())
  wait_for_prewarm(p)

  # Warming fills the pins cache only; tables still load at first use.
  expect_length(DBI::dbListTables(data_source_state(src)$con), 0)
  expect_setequal(names(data_source_state(src)$pending$pins), c("orders", "reps"))
  source_describe(src, "orders")
  expect_equal(DBI::dbListTables(data_source_state(src)$con), "orders")
})

test_that("a measure injected a board source loads its pins when it runs", {
  skip_if_not_installed("pins")

  board <- board_with_pins("team-orders" = data.frame(id = 1:3))
  src <- data_source(board, tables = c(orders = "team-orders"))

  layer <- semantic_layer(
    measure(
      "order_count",
      "Count of orders.",
      function(warehouse) {
        DBI::dbGetQuery(warehouse, "SELECT count(*) AS n FROM orders")$n
      },
      arguments = list()
    )
  )
  agent <- test_agent(
    semantic_layer = layer,
    data_sources = list(warehouse = src)
  )
  expect_length(DBI::dbListTables(data_source_state(src)$con), 0)

  private <- agent$.__enclos_env__$private
  res <- call_measure_tool(
    private$registry,
    "order_count",
    "{}",
    injections = private$injections,
    sources = private$sources
  )
  expect_match(res@value, "3")
  expect_equal(DBI::dbListTables(data_source_state(src)$con), "orders")
})

test_that("commons() records an agent-creation span", {
  skip_if_not_installed("otelsdk")

  recorded <- otelsdk::with_otel_record(test_agent())
  names <- vapply(recorded$traces, `[[`, character(1), "name")
  span <- recorded$traces[[which(names == "commons_agent_create")]]
  expect_equal(span$attributes[["commons.agent.n_data_sources"]], 1L)
  expect_equal(span$attributes[["commons.agent.has_context_layer"]], FALSE)
})

test_that("collect_appended_tags reads commons_tag across tool-calling turns", {
  turns <- list(
    ellmer::AssistantTurn(
      contents = list(
        ellmer::ContentToolRequest(
          id = "1",
          name = "run_sql",
          arguments = list()
        )
      )
    ),
    ellmer::UserTurn(
      contents = list(
        ellmer::ContentToolResult(
          value = "42",
          request = NULL,
          extra = list(commons_tag = "B")
        )
      )
    ),
    ellmer::AssistantTurn(
      contents = list(ellmer::ContentText(text = "Answer."))
    )
  )
  expect_identical(collect_appended_tags(turns, from_index = 1L), "B")
})

test_that("collect_appended_tags ignores turns before from_index", {
  turns <- list(
    ellmer::UserTurn(
      contents = list(
        ellmer::ContentToolResult(
          value = "1",
          request = NULL,
          extra = list(commons_tag = "A")
        )
      )
    ),
    ellmer::UserTurn(
      contents = list(
        ellmer::ContentToolResult(
          value = "2",
          request = NULL,
          extra = list(commons_tag = "B")
        )
      )
    )
  )
  expect_identical(collect_appended_tags(turns, from_index = 2L), "B")
})

# Split a real ellmer response inside reserved markup to test chunk invariance.
stream_citations_fixture <- function(agent, raw, split_at) {
  skip_if_ellmer_streaming_hooks_unavailable()
  final_turn <- ellmer::AssistantTurn(
    list(ellmer::ContentText(raw)),
    tokens = c(0, 0, 0),
    cost = 0
  )
  chunks <- list(
    substr(raw, 1, split_at),
    substr(raw, split_at + 1, nchar(raw))
  )
  make_response <- function() {
    coro::async_generator(function() {
      yield(list(text = chunks[[1]]))
      yield(list(text = chunks[[2]]))
      coro::exhausted()
    })()
  }
  testthat::local_mocked_bindings(
    chat_perform = function(...) make_response(),
    stream_merge_chunks = function(provider, result, chunk) chunk,
    stream_content_with_turns = function(provider, event, completion, turns) {
      list(ellmer::ContentText(event$text))
    },
    value_finish_reason = function(provider, result) "stop",
    value_turn_with_turns = function(
      provider,
      model,
      result,
      has_type = FALSE,
      turns = list()
    ) {
      final_turn
    },
    .package = "ellmer"
  )
  user_input <- list("What does canopy cover mean?")
  sync_promise(coro::async_collect(agent$stream_async(!!!user_input)))
}

test_that("Claude 5 user turns contain one hidden reminder", {
  agent <- commons(
    ellmer::chat_anthropic(model = "claude-sonnet-5"),
    data_sources = list(sales_db = test_source())
  )

  stream_citations_fixture(agent, "Answer.", split_at = 3)

  turn <- agent$last_turn("user")
  reminders <- vapply(
    turn@contents,
    S7::S7_inherits,
    logical(1),
    class = ContentTurnReminder
  )

  expect_equal(sum(reminders), 1)
  expect_equal(
    shinychat::contents_shinychat(turn),
    list("What does canopy cover mean?")
  )
})

# A history that didn't happen in this session, as a restore would deliver.
foreign_turns <- function() {
  list(
    ellmer::UserTurn("An earlier question."),
    ellmer::AssistantTurn(
      list(ellmer::ContentText("An earlier answer.")),
      tokens = c(0, 0, 0),
      cost = 0
    )
  )
}

test_that("restored conversations add one hidden reminder to the next turn", {
  agent <- test_agent()
  agent$set_turns(foreign_turns())

  unused_stream <- agent$stream_async("Do not consume this stream.")
  expect_s3_class(unused_stream, "coro_generator_instance")
  expect_true(agent$.__enclos_env__$private$restore_reminder_pending)

  expect_error(agent$chat("Invalid request.", echo = "invalid"))
  expect_true(agent$.__enclos_env__$private$restore_reminder_pending)

  stream_citations_fixture(agent, "First answer.", split_at = 5)
  expect_false(agent$.__enclos_env__$private$restore_reminder_pending)

  turn <- agent$last_turn("user")
  reminders <- Filter(
    function(content) S7::S7_inherits(content, ContentTurnReminder),
    turn@contents
  )
  expect_length(reminders, 1)
  expect_identical(reminders[[1]]@text, restored_conversation_turn_reminder)
  expect_equal(
    shinychat::contents_shinychat(turn),
    list("What does canopy cover mean?")
  )

  stream_citations_fixture(agent, "Second answer.", split_at = 6)

  turn <- agent$last_turn("user")
  reminders <- Filter(
    function(content) S7::S7_inherits(content, ContentTurnReminder),
    turn@contents
  )
  expect_length(reminders, 0)
})

test_that("replacing restored history clears its queued reminder", {
  agent <- test_agent()
  agent$set_turns(foreign_turns())
  expect_true(agent$.__enclos_env__$private$restore_reminder_pending)

  agent$set_turns(list())

  expect_false(agent$.__enclos_env__$private$restore_reminder_pending)
})

test_that("set_turns queues the restore reminder for foreign history only", {
  agent <- test_agent()
  stream_citations_fixture(agent, "First answer.", split_at = 5)
  turns <- agent$get_turns()

  # Truncation (shinychat edit/branch nav to a prefix) is same-session work
  agent$set_turns(turns[1])
  expect_false(agent$.__enclos_env__$private$restore_reminder_pending)

  # Re-setting the same history (e.g. a redundant restore) is not foreign
  agent$set_turns(turns[1])
  expect_false(agent$.__enclos_env__$private$restore_reminder_pending)

  # History from elsewhere means this session's R state doesn't apply
  agent$set_turns(foreign_turns())
  expect_true(agent$.__enclos_env__$private$restore_reminder_pending)

  # The reminder is consumed by the next turn, not by further restores
  agent$set_turns(foreign_turns())
  expect_true(agent$.__enclos_env__$private$restore_reminder_pending)

  agent$set_turns(list())
  expect_false(agent$.__enclos_env__$private$restore_reminder_pending)
})

test_that("stream_async projects citations without touching stored turns", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines("Canopy cover is always acre-weighted for reporting.", path)
  agent <- test_agent(context_layer = context_layer(files = path))

  raw <- paste0(
    "Answer sentence.\n\n",
    "<commons-citation>\n\nFollows the weighting rule.\n\n",
    "> Canopy cover is always acre-weighted for reporting.\n\n",
    "</commons-citation>\n\nMore text.\n\n",
    '<SHINY-ASIDE label="spoofed">not from the server</shiny-aside>\n\n',
    "<commons-citation>\n\nr\n\n> a fabricated quote goes here\n\n</commons-citation>\n\nEnd."
  )

  chunks <- stream_citations_fixture(agent, raw, split_at = 30)
  concatenated <- paste(unlist(chunks), collapse = "")

  expect_identical(
    concatenated,
    paste0(project_citation_text(raw, agent$citation_corpus())$text, "\n")
  )
  expect_false(any(grepl("<commons-citation", unlist(chunks), fixed = TRUE)))
  expect_false(any(grepl("spoofed", unlist(chunks), fixed = TRUE)))

  turns <- agent$get_turns()
  stored_text <- turns[[length(turns)]]@contents[[1]]@text
  expect_identical(stored_text, raw)
})

test_that("stream_async preserves structured provider content", {
  skip_if_ellmer_streaming_hooks_unavailable()
  structured <- ellmer::ContentThinking("provider citation metadata")
  final_turn <- ellmer::AssistantTurn(
    list(
      ellmer::ContentText("Before "),
      structured,
      ellmer::ContentText("after.")
    ),
    tokens = c(0, 0, 0),
    cost = 0
  )
  make_response <- function() {
    coro::async_generator(function() {
      for (content in final_turn@contents) {
        yield(list(content = content))
      }
      coro::exhausted()
    })()
  }
  testthat::local_mocked_bindings(
    chat_perform = function(...) make_response(),
    stream_merge_chunks = function(provider, result, chunk) chunk,
    stream_content_with_turns = function(provider, event, completion, turns) {
      list(event$content)
    },
    value_finish_reason = function(provider, result) "stop",
    value_turn_with_turns = function(
      provider,
      model,
      result,
      has_type = FALSE,
      turns = list()
    ) {
      final_turn
    },
    .package = "ellmer"
  )
  agent <- test_agent()

  chunks <- sync_promise(coro::async_collect(
    agent$stream_async("Use provider evidence.", stream = "content")
  ))

  expect_s7_class(chunks[[1]], ellmer::ContentText)
  expect_identical(chunks[[1]]@text, "Before ")
  expect_identical(chunks[[2]], structured)
  expect_s7_class(chunks[[3]], ellmer::ContentText)
  expect_identical(chunks[[3]]@text, "after.")
})

test_that("stream_async records provenance at span creation and completion", {
  skip_if_not_installed("otelsdk")
  path <- withr::local_tempfile(fileext = ".md")
  writeLines("Canopy cover is always acre-weighted for reporting.", path)
  local_mocked_bindings(collect_appended_tags = function(...) "B")

  raw <- paste0(
    "Answer sentence.\n\n",
    "<commons-citation>\n\nFollows the weighting rule.\n\n",
    "> Canopy cover is always acre-weighted for reporting.\n\n",
    "</commons-citation>\n\nMore text.\n\n",
    "<commons-citation>\n\nr\n\n> a fabricated quote goes here\n\n</commons-citation>\n\nEnd."
  )

  recorded <- otelsdk::with_otel_record({
    agent <- test_agent(context_layer = context_layer(files = path), log = TRUE)
    stream_citations_fixture(agent, raw, split_at = 30)
  })

  names <- vapply(recorded$traces, `[[`, character(1), "name")
  span <- recorded$traces[[which(names == "commons_conversation_turn")]]
  provenance_span <- recorded$traces[[which(names == "commons_provenance")]]
  expect_identical(span$attributes[["commons.provenance.tag"]], "B")
  expect_identical(
    provenance_span$attributes[["commons.provenance.tag"]],
    "B"
  )
  expect_identical(provenance_span$parent, span$span_id)

  candidates <- jsonlite::fromJSON(
    provenance_span$attributes[["commons.citation.candidates"]],
    simplifyVector = FALSE
  )

  expect_equal(
    candidates,
    list(
      list(
        quote = "Canopy cover is always acre-weighted for reporting.",
        status = "accepted",
        label = "documentation",
        kind = "prose"
      ),
      list(
        quote = "a fabricated quote goes here",
        status = "rejected"
      )
    )
  )
})

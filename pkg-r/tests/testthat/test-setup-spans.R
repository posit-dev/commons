# The spans R records while it sets up are pinned by the `setup_spans` member
# of tests/shared/traces.json, which the Python suite reads too.

setup_span_orders <- function() {
  data.frame(id = 1:3, total = c(10, 20, 30))
}

setup_span_customers <- function() {
  data.frame(id = 1:2, name = c("Ada", "Bo"))
}

setup_span_connection <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = parent.frame(2))
  DBI::dbWriteTable(con, "orders", setup_span_orders())
  DBI::dbWriteTable(con, "customers", setup_span_customers())
  con
}

setup_span_board <- function() {
  board_with_pins(orders = setup_span_orders(), customers = setup_span_customers())
}

setup_span_pins <- c(orders = "orders", customers = "customers")

setup_span_context_layer <- function() {
  paths <- vapply(
    c("Revenue means booked revenue.", "A customer is an account."),
    function(text) {
      path <- tempfile(fileext = ".md")
      writeLines(c("# Term", "", text), path)
      path
    },
    character(1)
  )
  context_layer(files = unname(paths))
}

# One function per fixture scenario. Each does its preparation and returns the
# step to record, so the span exporter sees the step under test and nothing else.
setup_span_runners <- list(
  "frames source" = function() {
    function() {
      data_source(
        orders = setup_span_orders(),
        customers = setup_span_customers()
      )
    }
  },
  "connection source" = function() {
    con <- setup_span_connection()
    function() data_source(con)
  },
  "board source" = function() {
    board <- setup_span_board()
    function() data_source(board, tables = setup_span_pins)
  },
  "board read" = function() {
    src <- data_source(setup_span_board(), tables = setup_span_pins)
    function() source_ensure_tables(src, c("orders", "customers"))
  },
  "context search" = function() {
    layer <- setup_span_context_layer()
    function() context_search(layer, "revenue")
  },
  "context prewarm" = function() {
    agent <- test_agent(
      context_layer = setup_span_context_layer(),
      data_sources = list(db = data_source(orders = setup_span_orders()))
    )
    function() agent$prewarm()
  },
  "agent create" = function() {
    withr::local_options(
      commons.allow_unsafe_fallback = TRUE,
      .local_envir = parent.frame()
    )
    state <- commons(
      data_sources = list(db = data_source(orders = setup_span_orders())),
      context_layer = setup_span_context_layer()
    )
    function() agent(test_client(), commons = state)
  },
  "agent create with measures" = function() {
    withr::local_options(
      commons.allow_unsafe_fallback = TRUE,
      .local_envir = parent.frame()
    )
    dictionary <- withr::local_tempfile(fileext = ".yaml")
    writeLines(
      c(
        "name: shop",
        "description: What the shop sold.",
        "tables:",
        "  - name: orders",
        "    description: One row per order.",
        "    columns:",
        "      - name: id",
        "        type: number",
        "      - name: total",
        "        type: number",
        "    definitions:",
        "      - name: big_order",
        "        description: Orders over 15.",
        "        expr: total > 15",
        "      - name: small_order",
        "        description: Orders of 15 or less.",
        "        expr: total <= 15"
      ),
      dictionary
    )
    source <- data_source(orders = setup_span_orders(), dictionary = dictionary)
    state <- commons(
      data_sources = list(db = source),
      semantic_layer = semantic_layer(
        measure("order_count", "Count of orders.", function() 3L)
      )
    )
    function() agent(test_client(), commons = state)
  },
  "chat server" = function() {
    skip_if_not_installed("shiny")
    skip_if_not_installed("shinychat")
    chat_agent <- test_agent()
    function() {
      shiny::testServer(
        function(input, output, session) {
          commons_server("chat", client = chat_agent)
        },
        session$flushReact()
      )
    }
  }
)

test_that("every setup-span scenario has a runner", {
  scenarios <- shared_fixture("traces")$setup_spans$scenarios
  expect_gt(length(scenarios), 0)
  expect_setequal(
    vapply(scenarios, `[[`, character(1), "name"),
    names(setup_span_runners)
  )
})

test_that("setup records the shared spans", {
  skip_on_cran()
  skip_if_not_installed("otelsdk")
  skip_if_not_installed("pins")
  skip_if_not_installed("ragnar")
  # No on-disk context cache, so the fixture's `persistent` and `cache_hit`
  # are FALSE whatever an earlier test left behind.
  withr::local_options(commons.context_cache = FALSE)

  for (scenario in shared_fixture("traces")$setup_spans$scenarios) {
    run <- setup_span_runners[[scenario$name]]()
    recorded <- otelsdk::with_otel_record(run())
    span_names <- vapply(recorded$traces, `[[`, character(1), "name")

    for (expected in scenario$spans) {
      info <- paste0(scenario$name, ": ", expected$name)
      expect_equal(sum(span_names == expected$name), 1L, info = info)
      span <- recorded$traces[[which(span_names == expected$name)]]
      attributes <- span$attributes
      expect_equal(
        attributes[sort(names(attributes))],
        expected$attributes[sort(names(expected$attributes))],
        info = info
      )
    }
  }
})

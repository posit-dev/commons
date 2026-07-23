test_sales <- function() {
  data.frame(
    order_id = sprintf("o%02d", 1:6),
    revenue = c(500, 900, 1200, 300, 2000, 750),
    region = c("EMEA", "Americas", "EMEA", "APAC", "Americas", "EMEA"),
    product_line = c(
      "Platform",
      "Services",
      "Platform",
      "Training",
      "Platform",
      "Services"
    ),
    rep = c("Ada", "Ada", "Bo", "Cy", "Bo", "Ada"),
    stringsAsFactors = FALSE
  )
}

test_source <- function() {
  data_source(sales = test_sales())
}

test_client <- function() {
  ellmer::chat_anthropic(model = "claude-sonnet-4-5")
}

# A board_temp() holding the given named values, each written as an rds pin.
board_with_pins <- function(...) {
  values <- rlang::list2(...)
  board <- pins::board_temp()
  suppressMessages(
    for (nm in names(values)) {
      pins::pin_write(board, values[[nm]], nm, type = "rds")
    }
  )
  board
}

test_agent <- function(
  context_layer = NULL,
  semantic_layer = NULL,
  data_sources = list(sales_db = test_source()),
  log = FALSE,
  ...
) {
  commons(
    test_client(),
    data_sources = data_sources,
    context_layer = context_layer,
    semantic_layer = semantic_layer,
    log = log,
    ...
  )
}

# share_trajectory_access() and enable_content_observability() latch
# process-wide; tests that exercise them start from a clean slate.
clear_granted_access <- function() {
  rm(list = ls(granted), envir = granted)
}

clear_observability_attempted <- function() {
  rm(list = ls(observability), envir = observability)
}

agent_tool <- function(agent, name) {
  tools <- agent$get_tools()
  tools[[which(vapply(tools, tool_name, character(1)) == name)]]
}

count_measure_tool <- function() {
  measure(
    "order_count",
    "Count orders, optionally filtered by region and a revenue ceiling.",
    function(region = NULL, revenue_under = NULL) {
      df <- test_sales()
      if (!is.null(region)) {
        df <- df[df$region %in% region, ]
      }
      if (!is.null(revenue_under)) {
        df <- df[df$revenue < revenue_under, ]
      }
      nrow(df)
    },
    arguments = list(
      region = ellmer::type_array(
        ellmer::type_enum(c("Americas", "APAC", "EMEA")),
        required = FALSE
      ),
      revenue_under = ellmer::type_number(required = FALSE)
    )
  )
}

sync_promise <- function(promise) {
  done <- FALSE
  success <- NULL
  error <- NULL

  promises::then(
    promise,
    function(result) {
      success <<- result
      done <<- TRUE
    },
    function(err) {
      error <<- err
      done <<- TRUE
    }
  )

  while (!done) {
    later::run_now(0.25)
  }

  if (!is.null(error)) {
    stop(error)
  }

  success
}

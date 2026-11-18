# Runs the scripted conversations behind tests/shared/traces/r/ with spans
# exported into a directory. write_trace_fixture() runs it in a process of its
# own, because otel reads the exporter settings once per process.
#
# Usage: Rscript trace-fixture.R <directory> [<package source>]

args <- commandArgs(trailingOnly = TRUE)
Sys.unsetenv(c(
  "OTEL_SDK_DISABLED",
  "OTEL_R_EMIT_SCOPES",
  "OTEL_R_SUPPRESS_SCOPES"
))
Sys.setenv(
  OTEL_TRACES_EXPORTER = "otlp/file",
  OTEL_EXPORTER_OTLP_TRACES_FILE = file.path(args[[1]], "trace-%N.jsonl"),
  OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true"
)
# A hyperlinked backtrace names the source file's absolute path.
options(cli.hyperlink = FALSE)
if (length(args) > 1 && nzchar(args[[2]])) {
  pkgload::load_all(args[[2]], helpers = FALSE, quiet = TRUE)
} else {
  library(commons)
}

documents <- c(
  "Orders are one row per placed order.",
  "A customer is an account that has placed at least one order."
)

reply <- function(...) {
  ellmer::AssistantTurn(list(...), tokens = c(0, 0, 0), cost = 0)
}

query <- function() {
  reply(ellmer::ContentToolRequest(
    id = "call-1",
    name = "run_sql",
    arguments = list(sql = "SELECT count(*) AS n FROM orders")
  ))
}

cited <- function(answer, quote) {
  reply(ellmer::ContentText(sprintf(
    "%s\n\n<citation>\n\nWhy.\n\n> %s\n\n</citation>",
    answer,
    quote
  )))
}

reply_text <- function(turn) {
  texts <- Filter(
    function(content) S7::S7_inherits(content, ellmer::ContentText),
    turn@contents
  )
  paste(
    vapply(texts, function(content) content@text, character(1)),
    collapse = ""
  )
}

# The model's replies, in the order the conversations ask for them.
script <- new.env(parent = emptyenv())
script$replies <- list()

source_frames <- function() {
  data_source(
    orders = data.frame(id = 1:3, total = c(10, 20, 30)),
    customers = data.frame(id = 1:2, name = c("Ada", "Bo"))
  )
}

scripted_agent <- function(replies, layer) {
  script$replies <- c(script$replies, replies)
  built <- agent(
    ellmer::chat_anthropic(model = "claude-sonnet-4-5"),
    commons = commons(
      data_sources = list(shop = source_frames()),
      context_layer = layer
    ),
    log = TRUE
  )
  stopifnot(isTRUE(built$.__enclos_env__$private$tracing))
  # shinychat sets this in an app.
  built$conversation_id <- basename(tempfile("c_"))
  built
}

ask <- function(agent, question) {
  done <- FALSE
  failure <- NULL
  promises::then(
    coro::async_collect(agent$stream_async(question)),
    function(value) done <<- TRUE,
    function(err) {
      failure <<- err
      done <<- TRUE
    }
  )
  while (!done) {
    later::run_now(0.1)
  }
  if (!is.null(failure)) stop(failure)
}

converse <- function() {
  # Replaces only the provider's network call; ellmer's chat loop, tool
  # calls, and spans run as they do with a live model.
  testthat::local_mocked_bindings(
    chat_perform = function(...) {
      turn <- script$replies[[1]]
      script$replies <- script$replies[-1]
      coro::async_generator(function() {
        yield(list(text = reply_text(turn), turn = turn))
        coro::exhausted()
      })()
    },
    stream_merge_chunks = function(provider, result, chunk) chunk,
    stream_content_with_turns = function(
      provider,
      event,
      completion = NULL,
      turns = list()
    ) {
      if (nzchar(event$text)) list(ellmer::ContentText(event$text)) else list()
    },
    value_finish_reason = function(provider, result) "stop",
    value_turn_with_turns = function(
      provider,
      model,
      result,
      has_type = FALSE,
      turns = list()
    ) {
      result$turn
    },
    .package = "ellmer"
  )
  withr::local_options(commons.allow_unsafe_fallback = TRUE)

  docs <- withr::local_tempdir()
  paths <- file.path(docs, sprintf("doc%d.md", seq_along(documents) - 1L))
  for (i in seq_along(documents)) {
    writeLines(c("# Term", "", documents[[i]]), paths[[i]])
  }
  layer <- context_layer(paths)

  first <- scripted_agent(
    list(
      query(),
      cited("There are three orders.", documents[[1]]),
      cited("Each order is one row.", "Orders are counted twice.")
    ),
    layer
  )
  ask(first, "How many orders are there?")
  ask(first, "Can an order appear twice?")

  second <- scripted_agent(
    list(reply(ellmer::ContentText("Hello. Ask me about orders or customers."))),
    layer
  )
  ask(second, "Hello")
  stopifnot(length(script$replies) == 0)
}

converse()

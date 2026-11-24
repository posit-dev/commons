otlp_test_attr <- function(key, value) {
  list(key = key, value = list(stringValue = value))
}

otlp_test_span <- function(
  trace_id,
  span_id,
  parent_span_id = NULL,
  name = "span",
  attributes = list(),
  start_time = "1",
  end_time = "2"
) {
  span <- list(
    traceId = trace_id,
    spanId = span_id,
    name = name,
    startTimeUnixNano = start_time,
    endTimeUnixNano = end_time,
    attributes = attributes
  )
  span$parentSpanId <- parent_span_id
  span
}

otlp_test_line <- function(spans) {
  jsonlite::toJSON(
    list(resourceSpans = list(list(scopeSpans = list(list(spans = spans))))),
    auto_unbox = TRUE
  )
}

chat_test_span <- function(
  trace_id,
  span_id,
  parent_span_id = NULL,
  conversation_id = NULL,
  input_messages = NULL,
  output_messages = NULL,
  system_instructions = NULL,
  start_time = "1",
  end_time = "2"
) {
  attributes <- list(otlp_test_attr("gen_ai.operation.name", "chat"))
  if (!is.null(conversation_id)) {
    attributes <- c(
      attributes,
      list(otlp_test_attr(
        shared_fixture("traces")$conversation_turn$conversation_attribute,
        conversation_id
      ))
    )
  }
  if (!is.null(system_instructions)) {
    attributes <- c(
      attributes,
      list(otlp_test_attr("gen_ai.system_instructions", system_instructions))
    )
  }
  if (!is.null(input_messages)) {
    attributes <- c(
      attributes,
      list(otlp_test_attr("gen_ai.input.messages", input_messages))
    )
  }
  if (!is.null(output_messages)) {
    attributes <- c(
      attributes,
      list(otlp_test_attr("gen_ai.output.messages", output_messages))
    )
  }
  otlp_test_span(
    trace_id,
    span_id,
    parent_span_id = parent_span_id,
    name = "chat test-model",
    attributes = attributes,
    start_time = start_time,
    end_time = end_time
  )
}

conversation_test_span <- function(trace_id, span_id, parent_span_id = NULL) {
  otlp_test_span(
    trace_id,
    span_id,
    parent_span_id = parent_span_id,
    name = "commons_conversation_turn"
  )
}

# Three single-span conversations starting at 100s, 200s, and 300s past the
# epoch, grouped by trace id.
staggered_test_line <- function() {
  json <- test_turn_json()
  otlp_test_line(list(
    chat_test_span(
      "t100",
      "s1",
      input_messages = json$input,
      start_time = "100000000000",
      end_time = "101000000000"
    ),
    chat_test_span(
      "t200",
      "s2",
      input_messages = json$input,
      start_time = "200000000000",
      end_time = "201000000000"
    ),
    chat_test_span(
      "t300",
      "s3",
      input_messages = json$input,
      start_time = "300000000000",
      end_time = "301000000000"
    )
  ))
}

test_turn_json <- function() {
  list(
    system = '[{"type":"text","content":"Be helpful."}]',
    input = paste0(
      '[{"role":"user","parts":[{"type":"text","content":"Roll a die."}]},',
      '{"role":"assistant","parts":[{"type":"tool_call","id":"c1",',
      '"name":"roll_die","arguments":{"sides":6}}]},',
      '{"role":"tool","parts":[{"type":"tool_call_response","id":"c1",',
      '"response":4}]}]'
    ),
    output = '[{"role":"assistant","parts":[{"type":"text","content":"You rolled a 4."}]}]'
  )
}

otlp_fixture_line <- function(line) {
  if (is.character(line)) {
    return(line)
  }
  as.character(jsonlite::toJSON(line, auto_unbox = TRUE, digits = NA))
}

expect_otlp_span <- function(span, expected, info = NULL) {
  expect_identical(span$trace_id, expected$trace_id, info = info)
  expect_identical(span$span_id, expected$span_id, info = info)
  expect_identical(span$parent_span_id, expected$parent_span_id, info = info)
  expect_identical(span$name, expected$name, info = info)
  if (!is.null(expected$start_time_unix_nano)) {
    expect_identical(span$start_time, expected$start_time_unix_nano, info = info)
  }
  if (!is.null(expected$end_time_unix_nano)) {
    expect_identical(span$end_time, expected$end_time_unix_nano, info = info)
  }
  expect_setequal(
    as.character(unique(names(span$attributes))),
    as.character(names(expected$attributes))
  )
  for (key in names(expected$attributes)) {
    expect_equal(
      span$attributes[[key]],
      expected$attributes[[key]],
      info = info
    )
  }
}

semconv_fixture_span <- function(attributes) {
  encoded <- lapply(names(attributes), function(key) {
    otlp_test_attr(key, otlp_fixture_line(attributes[[key]]))
  })
  parse_otlp_lines(otlp_test_line(list(
    otlp_test_span("t1", "s1", attributes = encoded)
  )))[[1]]
}

expect_semconv_turns <- function(turns, expected, info = NULL) {
  expect_equal(length(turns), length(expected), info = info)
  for (i in seq_along(expected)) {
    turn <- turns[[i]]
    e <- expected[[i]]
    expect_identical(turn@role, e$role, info = info)
    expect_equal(length(turn@contents), length(e$contents), info = info)
    for (j in seq_along(e$contents)) {
      content <- turn@contents[[j]]
      d <- e$contents[[j]]
      if (d$type == "text") {
        expect_true(S7::S7_inherits(content, ellmer::ContentText), info = info)
        expect_identical(content@text, d$text, info = info)
      } else if (d$type == "tool_request") {
        expect_true(
          S7::S7_inherits(content, ellmer::ContentToolRequest),
          info = info
        )
        expect_identical(content@id, d$id, info = info)
        expect_identical(content@name, d$name, info = info)
        expect_equal(content@arguments, d$arguments, info = info)
      } else if (d$type == "tool_result") {
        expect_true(
          S7::S7_inherits(content, ellmer::ContentToolResult),
          info = info
        )
        expect_equal(content@value, d$value, info = info)
        if (is.null(d$request)) {
          expect_null(content@request, info = info)
        } else {
          expect_identical(content@request@id, d$request$id, info = info)
          expect_identical(content@request@name, d$request$name, info = info)
        }
      } else {
        fail(paste0("unknown descriptor type ", d$type), info = info)
      }
    }
  }
}

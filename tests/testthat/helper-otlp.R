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
  input_messages = NULL,
  output_messages = NULL,
  system_instructions = NULL,
  end_time = "2"
) {
  attributes <- list(otlp_test_attr("gen_ai.operation.name", "chat"))
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
    end_time = end_time
  )
}

conversation_test_span <- function(trace_id, span_id, conversation_id) {
  otlp_test_span(
    trace_id,
    span_id,
    name = "commons_conversation_turn",
    attributes = list(otlp_test_attr("gen_ai.conversation.id", conversation_id))
  )
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

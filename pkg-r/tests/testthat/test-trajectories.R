test_that("parse_otlp_lines unwraps envelopes and flattens attributes", {
  line <- otlp_test_line(list(
    otlp_test_span(
      "t1",
      "s1",
      name = "demo",
      attributes = list(otlp_test_attr("gen_ai.operation.name", "chat"))
    )
  ))

  spans <- parse_otlp_lines(c(line, "not json", ""))

  expect_length(spans, 1)
  expect_equal(spans[[1]]$trace_id, "t1")
  expect_equal(spans[[1]]$span_id, "s1")
  expect_equal(spans[[1]]$name, "demo")
  expect_equal(spans[[1]]$attributes[["gen_ai.operation.name"]], "chat")
})

test_that("otlp_attribute_value handles OTLP value encodings", {
  expect_equal(otlp_attribute_value(list(stringValue = "x")), "x")
  expect_equal(otlp_attribute_value(list(intValue = "42")), 42)
  expect_equal(otlp_attribute_value(list(doubleValue = 1.5)), 1.5)
  expect_true(otlp_attribute_value(list(boolValue = TRUE)))
  expect_equal(
    otlp_attribute_value(
      list(arrayValue = list(values = list(list(stringValue = "a"))))
    ),
    list("a")
  )
})

test_that("trajectories rebuild ellmer turns from semconv messages", {
  json <- test_turn_json()
  spans <- parse_otlp_lines(otlp_test_line(list(
    chat_test_span(
      "t1",
      "s1",
      system_instructions = json$system,
      input_messages = json$input,
      output_messages = json$output
    )
  )))

  trajectories <- build_trajectories(spans)

  expect_length(trajectories, 1)
  turns <- trajectories[[1]]
  expect_length(turns, 5)
  expect_s7_class(turns[[1]], ellmer::SystemTurn)
  expect_equal(turns[[1]]@text, "Be helpful.")
  expect_s7_class(turns[[2]], ellmer::UserTurn)
  expect_equal(turns[[2]]@text, "Roll a die.")
  expect_s7_class(turns[[3]], ellmer::AssistantTurn)
  expect_s7_class(turns[[3]]@contents[[1]], ellmer::ContentToolRequest)
  expect_equal(turns[[3]]@contents[[1]]@arguments, list(sides = 6L))
  expect_s7_class(turns[[4]], ellmer::UserTurn)
  expect_s7_class(turns[[4]]@contents[[1]], ellmer::ContentToolResult)
  expect_equal(turns[[4]]@contents[[1]]@value, 4L)
  expect_equal(turns[[4]]@contents[[1]]@request@name, "roll_die")
  expect_s7_class(turns[[5]], ellmer::AssistantTurn)
  expect_equal(turns[[5]]@text, "You rolled a 4.")
})

test_that("exchange signatures compare semantic turn content", {
  request <- ellmer::ContentToolRequest(
    id = "call-1",
    name = "run_sql",
    arguments = list(limit = 10L, filters = list(region = "EMEA"))
  )
  exchange <- list(
    ellmer::UserTurn("Question"),
    ellmer::AssistantTurn(list(request)),
    ellmer::UserTurn(list(ellmer::ContentToolResult(
      value = list(rows = 3L),
      request = request
    ))),
    ellmer::AssistantTurn("Answer")
  )

  expect_identical(
    exchange_signature(exchange),
    list(
      list(
        role = "user",
        contents = list(list(type = "text", text = "Question"))
      ),
      list(
        role = "assistant",
        contents = list(list(
          type = "tool_request",
          id = "call-1",
          name = "run_sql",
          arguments = list(filters = list(region = "EMEA"), limit = 10L)
        ))
      ),
      list(
        role = "user",
        contents = list(list(
          type = "tool_result",
          id = "call-1",
          value = list(rows = 3L)
        ))
      ),
      list(
        role = "assistant",
        contents = list(list(type = "text", text = "Answer"))
      )
    )
  )
})

test_that("exchange prefix matching is exact and structured", {
  first <- list(
    ellmer::UserTurn("Q1"),
    ellmer::AssistantTurn("A1")
  )
  second <- list(
    ellmer::UserTurn("Q2"),
    ellmer::AssistantTurn("A2")
  )
  edited <- list(
    ellmer::UserTurn("Q2 edited"),
    ellmer::AssistantTurn("A2")
  )

  canonical <- lapply(list(first, second), exchange_signature)

  expect_true(exchange_prefix_matches(
    lapply(list(first), exchange_signature),
    canonical
  ))
  expect_true(exchange_prefix_matches(
    lapply(list(first, second), exchange_signature),
    canonical
  ))
  expect_false(exchange_prefix_matches(
    lapply(list(first, edited), exchange_signature),
    canonical
  ))
  expect_false(exchange_prefix_matches(
    lapply(list(first, second, edited), exchange_signature),
    canonical
  ))
})

test_that("only a completed final assistant response is attachable", {
  request <- ellmer::ContentToolRequest(
    id = "call-1",
    name = "run_sql",
    arguments = list(sql = "select 1")
  )

  expect_true(exchange_is_complete(list(
    ellmer::UserTurn("Q"),
    ellmer::AssistantTurn("A")
  )))
  expect_false(exchange_is_complete(list(ellmer::UserTurn("Q"))))
  expect_false(exchange_is_complete(list(
    ellmer::UserTurn("Q"),
    ellmer::AssistantTurn(list(request))
  )))
})

test_that("conversations carry their last chat activity time", {
  trajectories <- build_trajectories(parse_otlp_lines(staggered_test_line()))

  last_active <- attr(trajectories[[1]], "last_active")
  expect_s3_class(last_active, "POSIXct")
  expect_equal(as.numeric(last_active), 101)
})

test_that("rebuilt turns can be set on an ellmer chat", {
  json <- test_turn_json()
  spans <- parse_otlp_lines(otlp_test_line(list(
    chat_test_span("t1", "s1", input_messages = json$input)
  )))

  turns <- build_trajectories(spans)[[1]]
  chat <- test_client()
  expect_no_error(chat$set_turns(turns))
})

test_that("chat spans group by their conversation id across traces", {
  json <- test_turn_json()
  lines <- c(
    otlp_test_line(list(
      conversation_test_span("t1", "root1"),
      otlp_test_span(
        "t1",
        "agent1",
        parent_span_id = "root1",
        name = "invoke_agent"
      ),
      chat_test_span(
        "t1",
        "chat1",
        parent_span_id = "agent1",
        conversation_id = "conv-a",
        input_messages = '[{"role":"user","parts":[{"type":"text","content":"One."}]}]',
        end_time = "10"
      )
    )),
    otlp_test_line(list(
      conversation_test_span("t2", "root2"),
      otlp_test_span(
        "t2",
        "agent2",
        parent_span_id = "root2",
        name = "invoke_agent"
      ),
      chat_test_span(
        "t2",
        "chat2",
        parent_span_id = "agent2",
        conversation_id = "conv-a",
        input_messages = json$input,
        end_time = "20"
      )
    ))
  )

  trajectories <- build_trajectories(parse_otlp_lines(lines))

  expect_named(trajectories, "conv-a")
  expect_length(trajectories[[1]], 3)
  expect_equal(trajectories[[1]][[1]]@text, "Roll a die.")
})

text_semconv_message <- function(role, text) {
  list(role = role, parts = list(list(type = "text", content = text)))
}

semconv_messages_json <- function(messages) {
  jsonlite::toJSON(messages, auto_unbox = TRUE)
}

recorded_call_test_spans <- function(
  trace_id,
  conversation_id,
  messages,
  tag,
  end_time,
  citation_decisions = list(),
  dedicated_provenance_span = FALSE
) {
  root_id <- paste0(trace_id, "-root")
  agent_id <- paste0(trace_id, "-agent")
  attributes <- list(
    otlp_test_attr("commons.provenance.tag", tag),
    otlp_test_attr(
      "commons.citation.candidates",
      jsonlite::toJSON(citation_decisions, auto_unbox = TRUE)
    )
  )
  spans <- list(
    otlp_test_span(
      trace_id,
      root_id,
      name = "commons_conversation_turn",
      attributes = if (dedicated_provenance_span) list() else attributes,
      end_time = end_time
    ),
    otlp_test_span(
      trace_id,
      agent_id,
      parent_span_id = root_id,
      name = "invoke_agent",
      end_time = end_time
    ),
    chat_test_span(
      trace_id,
      paste0(trace_id, "-chat"),
      parent_span_id = agent_id,
      conversation_id = conversation_id,
      input_messages = semconv_messages_json(head(messages, -1L)),
      output_messages = semconv_messages_json(tail(messages, 1L)),
      end_time = end_time
    )
  )
  if (dedicated_provenance_span) {
    spans[[length(spans) + 1]] <- otlp_test_span(
      trace_id,
      paste0(trace_id, "-provenance"),
      parent_span_id = root_id,
      name = "commons_provenance",
      attributes = attributes,
      end_time = end_time
    )
  }
  spans
}

test_that("linear calls attach records to their own final exchanges", {
  q1 <- text_semconv_message("user", "Q1")
  a1 <- text_semconv_message("assistant", "A1")
  q2 <- text_semconv_message("user", "Q2")
  a2 <- text_semconv_message("assistant", "A2")
  spans <- parse_otlp_lines(otlp_test_line(c(
    recorded_call_test_spans("t1", "conv-a", list(q1, a1), "A", "10"),
    recorded_call_test_spans(
      "t2",
      "conv-a",
      list(q1, a1, q2, a2),
      "B",
      "20",
      dedicated_provenance_span = TRUE
    )
  )))

  provenance <- attr(build_trajectories(spans)[["conv-a"]], "provenance")

  expect_identical(
    vapply(provenance, `[[`, character(1), "provenance_tag"),
    c("A", "B")
  )
})

test_that("restored context stays unannotated when only the new call was recorded", {
  messages <- list(
    text_semconv_message("user", "Q1"),
    text_semconv_message("assistant", "A1"),
    text_semconv_message("user", "Q2"),
    text_semconv_message("assistant", "A2"),
    text_semconv_message("user", "Q3"),
    text_semconv_message("assistant", "A3")
  )
  spans <- parse_otlp_lines(otlp_test_line(
    recorded_call_test_spans("t3", "conv-a", messages, "C", "30")
  ))

  provenance <- attr(build_trajectories(spans)[["conv-a"]], "provenance")

  expect_length(provenance, 3)
  expect_true(all(is.na(vapply(
    provenance[1:2],
    `[[`,
    character(1),
    "provenance_tag"
  ))))
  expect_identical(provenance[[3]]$provenance_tag, "C")
})

test_that("calls after restore attach to their respective new exchanges", {
  restored <- list(
    text_semconv_message("user", "Q1"),
    text_semconv_message("assistant", "A1"),
    text_semconv_message("user", "Q2"),
    text_semconv_message("assistant", "A2")
  )
  q3a3 <- c(
    restored,
    list(
      text_semconv_message("user", "Q3"),
      text_semconv_message("assistant", "A3")
    )
  )
  q4a4 <- c(
    q3a3,
    list(
      text_semconv_message("user", "Q4"),
      text_semconv_message("assistant", "A4")
    )
  )
  spans <- parse_otlp_lines(otlp_test_line(c(
    recorded_call_test_spans("t3", "conv-a", q3a3, "A", "30"),
    recorded_call_test_spans("t4", "conv-a", q4a4, "C", "40")
  )))

  provenance <- attr(build_trajectories(spans)[["conv-a"]], "provenance")

  expect_true(is.na(provenance[[1]]$provenance_tag))
  expect_true(is.na(provenance[[2]]$provenance_tag))
  expect_identical(provenance[[3]]$provenance_tag, "A")
  expect_identical(provenance[[4]]$provenance_tag, "C")
})

test_that("switched conversations do not donate audit records", {
  old_path <- list(
    text_semconv_message("user", "Old question"),
    text_semconv_message("assistant", "Old answer")
  )
  latest_path <- list(
    text_semconv_message("user", "New question"),
    text_semconv_message("assistant", "New answer")
  )
  spans <- parse_otlp_lines(otlp_test_line(c(
    recorded_call_test_spans("old", "conv-a", old_path, "A", "10"),
    recorded_call_test_spans("new", "conv-a", latest_path, "C", "20")
  )))

  turns <- build_trajectories(spans)[["conv-a"]]
  provenance <- attr(turns, "provenance")

  expect_identical(split_exchanges(turns)[[1]][[1]]@text, "New question")
  expect_length(provenance, 1)
  expect_identical(provenance[[1]]$provenance_tag, "C")
})

test_that("edited paths retain shared-prefix records and drop abandoned records", {
  q1 <- text_semconv_message("user", "Q1")
  a1 <- text_semconv_message("assistant", "A1")
  old <- list(
    q1,
    a1,
    text_semconv_message("user", "Q2"),
    text_semconv_message("assistant", "A2")
  )
  edited <- list(
    q1,
    a1,
    text_semconv_message("user", "Q2 edited"),
    text_semconv_message("assistant", "A2 edited")
  )
  spans <- parse_otlp_lines(otlp_test_line(c(
    recorded_call_test_spans("t1", "conv-a", list(q1, a1), "A", "10"),
    recorded_call_test_spans("t2", "conv-a", old, "B", "20"),
    recorded_call_test_spans("t3", "conv-a", edited, "C", "30")
  )))

  provenance <- attr(build_trajectories(spans)[["conv-a"]], "provenance")

  expect_identical(provenance[[1]]$provenance_tag, "A")
  expect_identical(provenance[[2]]$provenance_tag, "C")
})

test_that("the latest descendant tool-loop span contributes one call record", {
  root1 <- otlp_test_span(
    "t1",
    "root1",
    name = "commons_conversation_turn",
    attributes = list(otlp_test_attr("commons.provenance.tag", "A"))
  )
  root2 <- otlp_test_span(
    "t2",
    "root2",
    name = "commons_conversation_turn",
    attributes = list(
      otlp_test_attr("commons.provenance.tag", "B"),
      otlp_test_attr(
        "commons.citation.candidates",
        '[{"quote":"Canopy cover.","status":"accepted"}]'
      )
    )
  )

  exchange1_turn <- paste0(
    '{"role":"user","parts":[{"type":"text","content":"What is the weather?"}]}'
  )
  exchange1_answer <- paste0(
    '{"role":"assistant","parts":[{"type":"text","content":"It\'s sunny."}]}'
  )
  exchange2_question <- paste0(
    '{"role":"user","parts":[{"type":"text","content":"Roll a die."}]}'
  )
  exchange2_tool_call <- paste0(
    '{"role":"assistant","parts":[{"type":"tool_call","id":"c1",',
    '"name":"roll_die","arguments":{"sides":6}}]}'
  )
  exchange2_tool_result <- paste0(
    '{"role":"tool","parts":[{"type":"tool_call_response","id":"c1",',
    '"response":4}]}'
  )
  exchange2_final <- paste0(
    '{"role":"assistant","parts":[{"type":"text","content":"You rolled a 4."}]}'
  )

  lines <- c(
    otlp_test_line(list(
      root1,
      otlp_test_span(
        "t1",
        "agent1",
        parent_span_id = "root1",
        name = "invoke_agent"
      ),
      chat_test_span(
        "t1",
        "chat1",
        parent_span_id = "agent1",
        conversation_id = "conv-a",
        input_messages = paste0("[", exchange1_turn, "]"),
        output_messages = paste0("[", exchange1_answer, "]"),
        end_time = "10"
      )
    )),
    otlp_test_line(list(
      root2,
      otlp_test_span(
        "t2",
        "agent2",
        parent_span_id = "root2",
        name = "invoke_agent"
      ),
      chat_test_span(
        "t2",
        "chat2a",
        parent_span_id = "agent2",
        conversation_id = "conv-a",
        input_messages = paste0(
          "[",
          paste(
            exchange1_turn,
            exchange1_answer,
            exchange2_question,
            sep = ","
          ),
          "]"
        ),
        output_messages = paste0("[", exchange2_tool_call, "]"),
        end_time = "20"
      ),
      chat_test_span(
        "t2",
        "chat2b",
        parent_span_id = "agent2",
        conversation_id = "conv-a",
        input_messages = paste0(
          "[",
          paste(
            exchange1_turn,
            exchange1_answer,
            exchange2_question,
            exchange2_tool_call,
            exchange2_tool_result,
            sep = ","
          ),
          "]"
        ),
        output_messages = paste0("[", exchange2_final, "]"),
        end_time = "30"
      )
    ))
  )

  trajectories <- build_trajectories(parse_otlp_lines(lines))
  turns <- trajectories[["conv-a"]]

  exchanges <- split_exchanges(turns)
  provenance <- attr(turns, "provenance")
  expect_length(exchanges, 2)
  expect_length(provenance, 2)

  expect_equal(exchanges[[1]][[1]]@text, "What is the weather?")
  expect_equal(provenance[[1]]$provenance_tag, "A")
  expect_equal(provenance[[1]]$citation_decisions, list())

  expect_equal(exchanges[[2]][[1]]@text, "Roll a die.")
  expect_equal(provenance[[2]]$provenance_tag, "B")
  expect_equal(
    provenance[[2]]$citation_decisions,
    list(list(quote = "Canopy cover.", status = "accepted"))
  )
})

test_that("conflicting records fail closed with one conversation warning", {
  messages <- list(
    text_semconv_message("user", "Q1"),
    text_semconv_message("assistant", "A1")
  )
  spans <- parse_otlp_lines(otlp_test_line(c(
    recorded_call_test_spans("t1", "conv-a", messages, "A", "10"),
    recorded_call_test_spans("t2", "conv-a", messages, "C", "20")
  )))

  expect_warning(
    turns <- build_trajectories(spans)[["conv-a"]],
    "conflicting audit records"
  )
  expect_true(is.na(attr(turns, "provenance")[[1]]$provenance_tag))
})

test_that("identical duplicate records collapse to one claim", {
  messages <- list(
    text_semconv_message("user", "Q1"),
    text_semconv_message("assistant", "A1")
  )
  spans <- parse_otlp_lines(otlp_test_line(c(
    recorded_call_test_spans("t1", "conv-a", messages, "A", "10"),
    recorded_call_test_spans("t2", "conv-a", messages, "A", "20")
  )))

  expect_no_warning(turns <- build_trajectories(spans)[["conv-a"]])
  expect_identical(attr(turns, "provenance")[[1]]$provenance_tag, "A")
})

test_that("an incomplete tool call does not receive provenance", {
  request <- list(
    role = "assistant",
    parts = list(list(
      type = "tool_call",
      id = "call-1",
      name = "run_sql",
      arguments = list(sql = "select 1")
    ))
  )
  messages <- list(text_semconv_message("user", "Q1"), request)
  spans <- parse_otlp_lines(otlp_test_line(
    recorded_call_test_spans("t1", "conv-a", messages, "A", "10")
  ))

  provenance <- attr(build_trajectories(spans)[["conv-a"]], "provenance")

  expect_length(provenance, 1)
  expect_true(is.na(provenance[[1]]$provenance_tag))
})

trajectory_scaling_spans <- function(n) {
  json <- test_turn_json()
  spans <- unlist(
    lapply(seq_len(n), function(i) {
      trace_id <- sprintf("scale-trace-%03d", i)
      root_id <- sprintf("scale-root-%03d", i)
      agent_id <- sprintf("scale-agent-%03d", i)
      conversation_id <- sprintf("scale-conversation-%03d", i)
      root <- otlp_test_span(
        trace_id,
        root_id,
        name = "commons_conversation_turn",
        attributes = list(
          otlp_test_attr("commons.provenance.tag", "B"),
          otlp_test_attr(
            "commons.citation.candidates",
            paste0(
              '[{"quote":"Scale quote ',
              i,
              '","status":"accepted",',
              '"label":"documentation","kind":"prose"}]'
            )
          )
        )
      )
      agent <- otlp_test_span(
        trace_id,
        agent_id,
        parent_span_id = root_id,
        name = "invoke_agent"
      )
      round_one <- chat_test_span(
        trace_id,
        sprintf("scale-chat-%03d-a", i),
        parent_span_id = agent_id,
        conversation_id = conversation_id,
        input_messages = json$input,
        end_time = as.character(i * 10L)
      )
      round_two <- chat_test_span(
        trace_id,
        sprintf("scale-chat-%03d-b", i),
        parent_span_id = agent_id,
        conversation_id = conversation_id,
        input_messages = json$input,
        output_messages = json$output,
        end_time = as.character(i * 10L + 1L)
      )
      list(root, agent, round_one, round_two)
    }),
    recursive = FALSE
  )
  parse_otlp_lines(otlp_test_line(spans))
}

test_that("trajectory reconstruction classifies spans a linear number of times", {
  spans <- trajectory_scaling_spans(40)
  chat_checks <- 0L
  original_is_chat_span <- is_chat_span

  local_mocked_bindings(
    is_chat_span = function(span) {
      chat_checks <<- chat_checks + 1L
      original_is_chat_span(span)
    }
  )

  trajectories <- build_trajectories(spans)
  provenance <- lapply(trajectories, attr, "provenance")

  expect_length(trajectories, 40)
  expect_lte(chat_checks, length(spans) * 3L)
  expect_identical(unname(lengths(provenance)), rep(1L, 40))
  expect_identical(
    unname(vapply(
      provenance,
      function(records) records[[1]]$provenance_tag,
      character(1)
    )),
    rep("B", 40)
  )
})

test_that("trajectory reconstruction parses each selected chat span once", {
  spans <- trajectory_scaling_spans(40)
  parsed <- character()
  original_trajectory_turns <- trajectory_turns

  local_mocked_bindings(
    trajectory_turns = function(span) {
      parsed <<- c(parsed, exchange_key(span))
      original_trajectory_turns(span)
    }
  )

  trajectories <- build_trajectories(spans)
  expected <- vapply(
    seq_len(40),
    function(i) {
      paste(
        sprintf("scale-trace-%03d", i),
        sprintf("scale-chat-%03d-b", i)
      )
    },
    character(1)
  )

  expect_length(trajectories, 40)
  expect_identical(anyDuplicated(parsed), 0L)
  expect_setequal(parsed, expected)
})

test_that("provenance defaults to NA/empty with no commons_conversation_turn ancestor", {
  spans <- parse_otlp_lines(otlp_test_line(list(
    chat_test_span(
      "lonetrace",
      "chat1",
      input_messages = '[{"role":"user","parts":[{"type":"text","content":"Hi."}]}]'
    )
  )))

  trajectories <- build_trajectories(spans)

  provenance <- attr(trajectories[["lonetrace"]], "provenance")
  expect_length(provenance, 1)
  expect_identical(
    provenance[[1]],
    list(provenance_tag = NA_character_, citation_decisions = list())
  )
})

test_that("chat spans without a wrapper fall back to their trace id", {
  spans <- parse_otlp_lines(otlp_test_line(list(
    chat_test_span(
      "lonetrace",
      "chat1",
      input_messages = '[{"role":"user","parts":[{"type":"text","content":"Hi."}]}]'
    )
  )))

  trajectories <- build_trajectories(spans)

  expect_named(trajectories, "lonetrace")
})

test_that("generic parts and empty messages are dropped", {
  input <- paste0(
    '[{"role":"user","parts":[{"type":"generic","class":"MyContent"}]},',
    '{"role":"user","parts":[{"type":"text","content":"Kept."}]}]'
  )
  spans <- parse_otlp_lines(otlp_test_line(list(
    chat_test_span("t1", "s1", input_messages = input)
  )))

  turns <- build_trajectories(spans)[[1]]

  expect_length(turns, 1)
  expect_equal(turns[[1]]@text, "Kept.")
})

test_that("trajectory_read reads OTLP files from a directory", {
  path <- withr::local_tempdir()
  json <- test_turn_json()
  line <- otlp_test_line(list(
    chat_test_span("t1", "s1", input_messages = json$input)
  ))
  writeLines(line, file.path(path, "trace-0.jsonl"))
  writeLines(line, file.path(path, "trace-latest.jsonl"))

  trajectories <- trajectory_read(path)

  expect_length(trajectories, 1)
  expect_length(read_local_spans(path), 1)
  expect_s7_class(trajectories[[1]][[1]], ellmer::UserTurn)
  expect_equal(
    attr(trajectories, "source"),
    list(kind = "local", path = normalizePath(path))
  )
})

test_that("local trace files can follow a custom exporter template", {
  path <- withr::local_tempdir()
  withr::local_envvar(
    OTEL_EXPORTER_OTLP_TRACES_FILE = file.path(path, "spans-%N.ndjson")
  )
  json <- test_turn_json()
  line <- otlp_test_line(list(
    chat_test_span("t1", "s1", input_messages = json$input)
  ))
  writeLines(line, file.path(path, "spans-0.ndjson"))
  writeLines(line, file.path(path, "spans-latest.ndjson"))

  expect_length(read_local_spans(path), 1)
})

test_that("the latest chat span wins across timestamp digit counts", {
  json <- test_turn_json()
  early <- chat_test_span(
    "t1",
    "s1",
    input_messages = json$input,
    end_time = "999"
  )
  late <- chat_test_span(
    "t1",
    "s2",
    input_messages = json$input,
    output_messages = json$output,
    end_time = "1000"
  )
  spans <- parse_otlp_lines(otlp_test_line(list(early, late)))

  trajectories <- build_trajectories(spans)

  expect_length(trajectories, 1)
  final <- trajectories[[1]][[length(trajectories[[1]])]]
  expect_s7_class(final, ellmer::AssistantTurn)
  expect_equal(final@text, "You rolled a 4.")
})

test_that("trajectory_read hints when no conversation carries content", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  line <- otlp_test_line(list(
    chat_test_span("t1", "s1"),
    chat_test_span("t2", "s2")
  ))
  writeLines(line, file.path(path, "trace-0.jsonl"))

  expect_snapshot(.res <- trajectory_read(path))
  expect_length(.res, 0)
})

test_that("trajectory_read drops content-less conversations, keeping the rest", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  json <- test_turn_json()
  line <- otlp_test_line(list(
    chat_test_span("t1", "s1", input_messages = json$input),
    chat_test_span("t2", "s2")
  ))
  writeLines(line, file.path(path, "trace-0.jsonl"))

  expect_snapshot(.res <- trajectory_read(path))
  expect_length(.res, 1)
  expect_s7_class(.res[[1]][[1]], ellmer::UserTurn)
})

test_that("from/to filter conversations by chat-span start time", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  writeLines(staggered_test_line(), file.path(path, "trace-0.jsonl"))

  expect_named(
    trajectory_read(path, from = .POSIXct(200, tz = "UTC")),
    c("t200", "t300")
  )
  expect_named(
    trajectory_read(path, to = .POSIXct(200, tz = "UTC")),
    "t100"
  )
  expect_named(
    trajectory_read(
      path,
      from = .POSIXct(150, tz = "UTC"),
      to = .POSIXct(250, tz = "UTC")
    ),
    "t200"
  )
})

test_that("a conversation continuing past `to` returns history as of `to`", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  json <- test_turn_json()
  line <- otlp_test_line(list(
    chat_test_span(
      "t1",
      "s1",
      input_messages = json$input,
      start_time = "100000000000",
      end_time = "101000000000"
    ),
    chat_test_span(
      "t1",
      "s2",
      input_messages = json$input,
      output_messages = json$output,
      start_time = "300000000000",
      end_time = "301000000000"
    )
  ))
  writeLines(line, file.path(path, "trace-0.jsonl"))

  full <- trajectory_read(path)
  as_of <- trajectory_read(path, to = .POSIXct(200, tz = "UTC"))

  expect_s7_class(full[[1]][[length(full[[1]])]], ellmer::AssistantTurn)
  expect_length(as_of[[1]], length(full[[1]]) - 1)
})

test_that("grouping by chat-span id survives a filtered-out wrapper", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  json <- test_turn_json()
  line <- otlp_test_line(list(
    conversation_test_span("t1", "root1"),
    chat_test_span(
      "t1",
      "chat1",
      parent_span_id = "root1",
      conversation_id = "conv-a",
      input_messages = json$input,
      start_time = "200000000000",
      end_time = "201000000000"
    )
  ))
  writeLines(line, file.path(path, "trace-0.jsonl"))

  trajectories <- trajectory_read(path, from = .POSIXct(150, tz = "UTC"))

  expect_named(trajectories, "conv-a")
})

test_that("n keeps the most recent conversations", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  writeLines(staggered_test_line(), file.path(path, "trace-0.jsonl"))

  expect_named(trajectory_read(path, n = 2), c("t200", "t300"))
  expect_named(trajectory_read(path, n = 5), c("t100", "t200", "t300"))
  expect_named(
    trajectory_read(path, n = 1, from = .POSIXct(150, tz = "UTC")),
    "t300"
  )
})

test_that("trajectory_read validates n, from, and to", {
  expect_snapshot(trajectory_read(n = 0), error = TRUE)
  expect_snapshot(trajectory_read(n = "x"), error = TRUE)
  expect_snapshot(trajectory_read(from = "not a date"), error = TRUE)
  expect_snapshot(trajectory_read(to = 1:2), error = TRUE)
  expect_snapshot(trajectory_read("dir", 5), error = TRUE)
})

test_that("Date and string window bounds mean local midnight", {
  expect_equal(
    check_window_bound(as.Date("2026-07-22")),
    as.POSIXct("2026-07-22")
  )
  expect_equal(check_window_bound("2026-07-22"), as.POSIXct("2026-07-22"))
})

test_that("window bound strings must parse completely", {
  expect_equal(
    check_window_bound("2026-07-22T14:30:00"),
    as.POSIXct("2026-07-22 14:30:00")
  )
  expect_equal(
    check_window_bound("2026-07-22 14:30"),
    as.POSIXct("2026-07-22 14:30:00")
  )
  expect_error(check_window_bound("2026-07-22oops"), "must be")
  expect_error(check_window_bound("2026-07-22 14:30:00Z"), "must be")
})

test_that("a Connect read recovers a wrapper the `from` pushdown dropped", {
  withr::local_envvar(
    CONNECT_SERVER = "https://connect.example.com",
    CONNECT_API_KEY = "key"
  )
  json <- test_turn_json()
  wrapper <- conversation_test_span("t1", "root1")
  chat <- chat_test_span(
    "t1",
    "chat1",
    parent_span_id = "root1",
    conversation_id = "conv-a",
    input_messages = json$input,
    start_time = "200000000000",
    end_time = "201000000000"
  )
  state <- new.env()
  state$froms <- list()
  local_mocked_bindings(
    connect_trace_lines = function(client, guid, from = NULL, to = NULL, ...) {
      state$froms <- c(state$froms, list(from))
      if (is.null(from)) {
        otlp_test_line(list(wrapper, chat))
      } else {
        otlp_test_line(list(chat))
      }
    }
  )

  trajectories <- trajectory_read(
    "ea3c1445-cb71-42df-a2f2-bdb18874ef41",
    from = .POSIXct(150, tz = "UTC")
  )

  expect_length(state$froms, 2)
  expect_null(state$froms[[2]])
  expect_named(trajectories, "conv-a")
})

test_that("a windowed Connect read with intact ancestry fetches once", {
  withr::local_envvar(
    CONNECT_SERVER = "https://connect.example.com",
    CONNECT_API_KEY = "key"
  )
  json <- test_turn_json()
  state <- new.env()
  state$fetches <- 0
  local_mocked_bindings(
    connect_trace_lines = function(client, guid, from = NULL, to = NULL, ...) {
      state$fetches <- state$fetches + 1
      otlp_test_line(list(
        conversation_test_span("t1", "root1"),
        chat_test_span(
          "t1",
          "chat1",
          parent_span_id = "root1",
          conversation_id = "conv-a",
          input_messages = json$input,
          start_time = "200000000000",
          end_time = "201000000000"
        )
      ))
    }
  )

  trajectories <- trajectory_read(
    "ea3c1445-cb71-42df-a2f2-bdb18874ef41",
    from = .POSIXct(150, tz = "UTC")
  )

  expect_equal(state$fetches, 1)
  expect_named(trajectories, "conv-a")
})

test_that("enough_trace_lines is satisfied once n conversations have content", {
  lines <- staggered_test_line()

  enough <- enough_trace_lines(2, NULL, NULL)
  expect_true(enough(lines))

  enough <- enough_trace_lines(5, NULL, NULL)
  expect_false(enough(lines))

  enough <- enough_trace_lines(1, .POSIXct(250, tz = "UTC"), NULL)
  expect_true(enough(lines))
})

test_that("enough_trace_lines waits for a chat span's trailing wrapper", {
  json <- test_turn_json()
  chat_only <- otlp_test_line(list(
    chat_test_span(
      "t1",
      "chat1",
      parent_span_id = "root1",
      input_messages = json$input
    )
  ))
  with_wrapper <- c(
    chat_only,
    otlp_test_line(list(conversation_test_span("t1", "root1")))
  )

  enough <- enough_trace_lines(1, NULL, NULL)
  expect_false(enough(chat_only))
  expect_true(enough(with_wrapper))
})

test_that("trajectory_read stops Connect paging after n conversations", {
  withr::local_envvar(
    CONNECT_SERVER = "https://connect.example.com",
    CONNECT_API_KEY = "key"
  )
  json <- test_turn_json()
  pages <- lapply(c("300", "200", "100"), function(seconds) {
    otlp_test_line(list(chat_test_span(
      paste0("t", seconds),
      paste0("s", seconds),
      input_messages = json$input,
      start_time = paste0(seconds, "000000000"),
      end_time = paste0(seconds, "500000000")
    )))
  })
  state <- new.env()
  state$served <- 0
  local_mocked_bindings(
    connect_trace_lines = function(
      client,
      guid,
      from = NULL,
      to = NULL,
      enough = NULL,
      ...
    ) {
      lines <- character()
      for (page in pages) {
        lines <- c(lines, page)
        state$served <- state$served + 1
        if (!is.null(enough) && enough(lines)) {
          break
        }
      }
      lines
    }
  )

  trajectories <- trajectory_read(
    "ea3c1445-cb71-42df-a2f2-bdb18874ef41",
    n = 1
  )

  expect_equal(state$served, 1)
  expect_named(trajectories, "t300")
  expect_equal(
    attr(trajectories, "source"),
    list(
      kind = "connect",
      server = "https://connect.example.com",
      content_guid = "ea3c1445-cb71-42df-a2f2-bdb18874ef41"
    )
  )
})

test_that("trajectory_read returns an empty list for a missing directory", {
  expect_length(trajectory_read(file.path(tempdir(), "nope")), 0)
})

test_that("trajectory_read validates source", {
  expect_snapshot(trajectory_read(1:2), error = TRUE)
})

test_that("a GUID source resolves to a Connect read", {
  withr::local_envvar(
    CONNECT_SERVER = "https://connect.example.com",
    CONNECT_API_KEY = "key"
  )

  resolved <- resolve_trajectory_source(
    "ea3c1445-cb71-42df-a2f2-bdb18874ef41"
  )

  expect_equal(resolved$kind, "connect")
  expect_equal(resolved$guid, "ea3c1445-cb71-42df-a2f2-bdb18874ef41")
  expect_equal(resolved$client$server, "https://connect.example.com")
})

test_that("a content URL source carries its own server", {
  withr::local_envvar(CONNECT_SERVER = NA, CONNECT_API_KEY = "key")

  resolved <- resolve_trajectory_source(
    "https://connect.example.com/content/ea3c1445-cb71-42df-a2f2-bdb18874ef41/"
  )

  expect_equal(resolved$kind, "connect")
  expect_equal(resolved$guid, "ea3c1445-cb71-42df-a2f2-bdb18874ef41")
  expect_equal(resolved$client$server, "https://connect.example.com")
})

test_that("a dashboard URL source carries its own server", {
  withr::local_envvar(CONNECT_SERVER = NA, CONNECT_API_KEY = "key")

  resolved <- resolve_trajectory_source(
    "https://connect.example.com/connect/#/apps/ea3c1445-cb71-42df-a2f2-bdb18874ef41/access"
  )

  expect_equal(resolved$kind, "connect")
  expect_equal(resolved$guid, "ea3c1445-cb71-42df-a2f2-bdb18874ef41")
  expect_equal(resolved$client$server, "https://connect.example.com")
})

test_that("a URL without a recognizable GUID errors rather than reading locally", {
  expect_snapshot(
    resolve_trajectory_source("https://connect.example.com/other"),
    error = TRUE
  )
})

test_that("NULL source on Connect reads this content's traces", {
  withr::local_envvar(
    CONNECT_CONTENT_GUID = "ea3c1445-cb71-42df-a2f2-bdb18874ef41",
    CONNECT_SERVER = "https://connect.example.com",
    CONNECT_API_KEY = "key"
  )

  resolved <- resolve_trajectory_source(NULL)

  expect_equal(resolved$kind, "connect")
  expect_equal(resolved$guid, "ea3c1445-cb71-42df-a2f2-bdb18874ef41")
})

test_that("NULL source uses the project deployment record", {
  withr::local_envvar(
    POSIT_PRODUCT = NA,
    CONNECT_CONTENT_GUID = NA,
    CONNECT_SERVER = NA,
    CONNECT_API_KEY = "key"
  )
  dir <- withr::local_tempdir()
  record_dir <- file.path(dir, "rsconnect", "documents", "app.R", "server")
  dir.create(record_dir, recursive = TRUE)
  writeLines(
    c(
      "name: my-agent",
      "hostUrl: https://connect.example.com/__api__",
      "url: https://connect.example.com/content/ea3c1445-cb71-42df-a2f2-bdb18874ef41/"
    ),
    file.path(record_dir, "my-agent.dcf")
  )
  withr::local_dir(dir)

  resolved <- resolve_trajectory_source(NULL)

  expect_equal(resolved$kind, "connect")
  expect_equal(resolved$guid, "ea3c1445-cb71-42df-a2f2-bdb18874ef41")
  expect_equal(resolved$client$server, "https://connect.example.com")
})

test_that("NULL source falls back to the local traces directory", {
  withr::local_envvar(
    POSIT_PRODUCT = NA,
    CONNECT_CONTENT_GUID = NA,
    OTEL_EXPORTER_OTLP_TRACES_FILE = NA,
    COMMONS_TRACES_DIR = NA
  )
  withr::local_dir(withr::local_tempdir())

  resolved <- resolve_trajectory_source(NULL)

  expect_equal(resolved$kind, "local")
  expect_equal(resolved$path, file.path(tempdir(), "commons-traces"))
})

test_that("local_traces_dir follows the active file exporter", {
  withr::local_envvar(
    OTEL_EXPORTER_OTLP_TRACES_FILE = "/some/dir/trace-%N.jsonl"
  )
  expect_equal(local_traces_dir(), "/some/dir")
})

test_that("is_content_guid recognizes GUIDs", {
  expect_true(is_content_guid("ea3c1445-cb71-42df-a2f2-bdb18874ef41"))
  expect_false(is_content_guid("not-a-guid"))
  expect_false(is_content_guid("/tmp/logs"))
})

test_that("content_url_guid extracts the server and GUID", {
  parsed <- content_url_guid(
    "https://connect.example.com/rsc/content/ea3c1445-cb71-42df-a2f2-bdb18874ef41/foo"
  )
  expect_equal(parsed$server, "https://connect.example.com/rsc")
  expect_equal(parsed$guid, "ea3c1445-cb71-42df-a2f2-bdb18874ef41")

  parsed <- content_url_guid(
    "https://connect.example.com/connect/#/apps/ea3c1445-cb71-42df-a2f2-bdb18874ef41/logs"
  )
  expect_equal(parsed$server, "https://connect.example.com")
  expect_equal(parsed$guid, "ea3c1445-cb71-42df-a2f2-bdb18874ef41")

  parsed <- content_url_guid(
    "https://connect.example.com/#/apps/ea3c1445-cb71-42df-a2f2-bdb18874ef41"
  )
  expect_equal(parsed$server, "https://connect.example.com")

  expect_null(content_url_guid("https://connect.example.com/other"))
  expect_null(content_url_guid("plain-string"))
})

test_that("deployment records are found in project subdirectories", {
  dir <- withr::local_tempdir()
  record_dir <- file.path(dir, "app", "rsconnect", "connect.example.com", "me")
  dir.create(record_dir, recursive = TRUE)
  writeLines(
    c(
      "name: my-agent",
      "hostUrl: https://connect.example.com/__api__",
      "url: https://connect.example.com/content/ea3c1445-cb71-42df-a2f2-bdb18874ef41/"
    ),
    file.path(record_dir, "my-agent.dcf")
  )

  deployment <- find_rsconnect_deployment(dir)

  expect_equal(deployment$guid, "ea3c1445-cb71-42df-a2f2-bdb18874ef41")
})

test_that("read_deployment_record skips records without a GUID", {
  file <- withr::local_tempfile(fileext = ".dcf")
  writeLines(
    c("name: old-style", "url: https://connect.example.com/my-agent/"),
    file
  )
  expect_null(read_deployment_record(file))
})

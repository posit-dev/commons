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
  span <- list(traceId = trace_id, spanId = span_id, name = name)
  # A NULL time leaves the field out of the span.
  span$startTimeUnixNano <- start_time
  span$endTimeUnixNano <- end_time
  span$attributes <- attributes
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
          requests <- Filter(
            function(c) S7::S7_inherits(c, ellmer::ContentToolRequest),
            unlist(lapply(turns, function(t) t@contents), recursive = FALSE)
          )
          expect_true(
            any(vapply(requests, identical, logical(1), content@request)),
            info = info
          )
        }
      } else {
        fail(paste0("unknown descriptor type ", d$type), info = info)
      }
    }
  }
}

trajectory_fixture_span <- function(span) {
  attributes <- list()
  if (isTRUE(span[["chat"]])) {
    attributes[["gen_ai.operation.name"]] <- "chat"
  }
  shorthand <- c(
    conversation = "gen_ai.conversation.id",
    system = "gen_ai.system_instructions",
    input = "gen_ai.input.messages",
    output = "gen_ai.output.messages"
  )
  for (field in names(shorthand)) {
    if (!is.null(span[[field]])) {
      attributes[[shorthand[[field]]]] <- span[[field]]
    }
  }
  for (key in names(span[["attributes"]])) {
    attributes[key] <- list(span[["attributes"]][[key]])
  }
  otlp_test_span(
    span[["trace"]],
    span[["span"]],
    parent_span_id = span[["parent"]],
    name = if (isTRUE(span[["chat"]])) "chat test-model" else span[["name"]],
    attributes = lapply(names(attributes), function(key) {
      otlp_test_attr(key, otlp_fixture_line(attributes[[key]]))
    }),
    start_time = fixture_time(span[["start"]], "1"),
    end_time = fixture_time(span[["end"]], "2")
  )
}

# `false` leaves the timestamp out; an absent one takes its default.
fixture_time <- function(time, default) {
  if (isFALSE(time)) NULL else time %||% default
}

fixture_instant <- function(x) {
  if (is.null(x)) NULL else .POSIXct(x, tz = "UTC")
}

trajectory_fixture_run <- function(member, case, read = FALSE) {
  spans <- case[["spans"]] %||% member[["spans"]]
  line <- otlp_test_line(lapply(spans, trajectory_fixture_span))
  notices <- character()
  trajectories <- withCallingHandlers(
    if (read) {
      path <- withr::local_tempdir()
      writeLines(line, file.path(path, "trace-1.jsonl"))
      trajectory_read(
        path,
        n = case[["n"]],
        from = fixture_instant(case[["since"]]),
        to = fixture_instant(case[["until"]])
      )
    } else {
      build_trajectories(parse_otlp_lines(line))
    },
    warning = function(cnd) {
      notices <<- c(notices, "warning")
      invokeRestart("muffleWarning")
    },
    message = function(cnd) {
      notices <<- c(notices, "message")
      invokeRestart("muffleMessage")
    }
  )
  list(trajectories = trajectories, notices = notices)
}

expect_trajectories <- function(trajectories, expected, info = NULL) {
  expect_identical(
    names(trajectories) %||% character(),
    vapply(expected, function(e) e[["id"]], character(1)),
    info = info
  )
  for (e in expected) {
    t <- trajectories[[e[["id"]]]]
    if (!is.null(e[["turns"]])) {
      expect_semconv_turns(t[["turns"]], e[["turns"]], info)
    }
    if (!is.null(e[["provenance"]])) {
      records <- attr(t[["turns"]], "provenance")
      expect_equal(length(records), length(e[["provenance"]]), info = info)
      for (i in seq_along(e[["provenance"]])) {
        r <- records[[i]]
        p <- e[["provenance"]][[i]]
        expect_identical(
          r[["provenance_tag"]],
          p[["tag"]] %||% NA_character_,
          info = info
        )
        expect_equal(
          r[["citation_decisions"]],
          p[["decisions"]],
          info = info
        )
      }
    }
    if ("user" %in% names(e)) {
      expect_identical(
        t[["user"]],
        e[["user"]] %||% NA_character_,
        info = info
      )
    }
    if (!is.null(e[["last_active"]])) {
      expect_equal(
        as.numeric(t[["last_active"]]),
        e[["last_active"]],
        info = info
      )
    }
  }
}

expect_trajectory_member <- function(member, read = FALSE) {
  expect_gt(length(member[["cases"]]), 0)
  for (case in member[["cases"]]) {
    info <- case[["name"]]
    if (isTRUE(case[["error"]])) {
      expect_error(trajectory_fixture_run(member, case, read), info = info)
      next
    }
    result <- trajectory_fixture_run(member, case, read)
    expect_identical(
      result[["notices"]],
      if (is.null(case[["notice"]])) character() else case[["notice"]],
      info = info
    )
    expect_trajectories(result[["trajectories"]], case[["trajectories"]], info)
  }
}

expect_window_bound_member <- function(member) {
  withr::local_timezone("America/Denver")
  expect_gt(length(member[["cases"]]), 0)
  for (case in member[["cases"]]) {
    value <- if (!is.null(case[["date"]])) {
      as.Date(case[["date"]])
    } else {
      case[["string"]]
    }
    if (is.null(case[["utc"]])) {
      expect_error(check_window_bound(value), "must be", info = case[["name"]])
    } else {
      expect_equal(
        as.numeric(check_window_bound(value)),
        as.numeric(as.POSIXct(case[["utc"]], tz = "UTC")),
        info = case[["name"]]
      )
    }
  }
}

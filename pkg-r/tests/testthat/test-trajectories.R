semconv <- shared_fixture(file.path("trajectories", "semconv"))
build <- shared_fixture(file.path("trajectories", "build"))

test_that("parse_otlp_lines unwraps envelopes and flattens attributes", {
  cases <- shared_fixture(file.path("trajectories", "otlp"))$lines$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    lines <- vapply(case$lines, otlp_fixture_line, character(1))
    spans <- parse_otlp_lines(lines)
    expect_length(spans, length(case$spans))
    for (i in seq_along(case$spans)) {
      expect_otlp_span(spans[[i]], case$spans[[i]], info = case$name)
    }
  }
})

test_that("otlp_attribute_value handles OTLP value encodings", {
  cases <- shared_fixture(file.path("trajectories", "otlp"))$attribute_values$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    expect_equal(otlp_attribute_value(case$value), case$expected, info = case$name)
  }
})

test_that("trajectories rebuild ellmer turns from semconv messages", {
  cases <- semconv$turns$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    expect_semconv_turns(
      trajectory_turns(semconv_fixture_span(case$attributes)),
      case$turns,
      info = case$name
    )
  }
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
  expect_trajectory_member(build$last_active)
  case <- build$last_active$cases[[1]]
  result <- trajectory_fixture_run(build$last_active, case)
  expect_s3_class(result$trajectories[[1]]$last_active, "POSIXct")
})

test_that("trajectory_read associates session users with their conversations", {
  expect_trajectory_member(build$session_users)
})

test_that("conversation users come from the earliest recorded non-title chat", {
  expect_trajectory_member(build$earliest_user)
})

test_that("chat spans group by their conversation id across traces", {
  expect_trajectory_member(build$conversation_id)
})

test_that("title generation does not replace the conversation it titles", {
  expect_trajectory_member(build$title_spans)
})

test_that("missing latest input recovers history and subsequent outputs", {
  expect_trajectory_member(build$missing_latest_input)
})

test_that("missing input in a later agent turn preserves earlier exchanges", {
  expect_trajectory_member(build$missing_later_input)
})

test_that("missing initial rich input is represented explicitly", {
  expect_trajectory_member(build$missing_initial_input)
})

test_that("missing input outside an agent turn does not invent a user turn", {
  expect_trajectory_member(build$missing_input_outside_turn)
})

test_that("linear calls attach records to their own final exchanges", {
  expect_trajectory_member(build$provenance)
})

test_that("exchanges split at plain user turns", {
  expect_trajectory_member(build$exchanges)
})

test_that("restored context stays unannotated when only the new call was recorded", {
  expect_trajectory_member(build$restored_context)
})

test_that("calls after restore attach to their respective new exchanges", {
  expect_trajectory_member(build$after_restore)
})

test_that("switched conversations do not donate audit records", {
  expect_trajectory_member(build$switched_conversation)
})

test_that("edited paths retain shared-prefix records and drop abandoned records", {
  expect_trajectory_member(build$edited_paths)
})

test_that("the latest descendant tool-loop span contributes one call record", {
  expect_trajectory_member(build$tool_loop)
})

test_that("conflicting records fail closed with one conversation warning", {
  expect_trajectory_member(build$conflicting_records)
})

test_that("identical duplicate records collapse to one claim", {
  expect_trajectory_member(build$duplicate_records)
})

test_that("an incomplete tool call does not receive provenance", {
  expect_trajectory_member(build$incomplete_call)
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
  provenance <- lapply(trajectories, function(x) attr(x$turns, "provenance"))

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
  expect_trajectory_member(build$no_provenance)
})

test_that("chat spans without a wrapper fall back to their trace id", {
  expect_trajectory_member(build$trace_id_fallback)
})

test_that("generic parts and empty messages are dropped", {
  cases <- semconv$dropped$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    expect_semconv_turns(
      trajectory_turns(semconv_fixture_span(case$attributes)),
      case$turns,
      info = case$name
    )
  }
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
  expect_named(trajectories[[1]], c("turns", "last_active", "user"))
  expect_identical(trajectories[[1]]$user, NA_character_)
  expect_s7_class(trajectories[[1]]$turns[[1]], ellmer::UserTurn)
  expect_s3_class(trajectories[[1]]$last_active, "POSIXct")
})

test_that("local trace files are named as the shared fixture pins", {
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  cases <- shared_fixture("traces")$file_naming$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    expect_identical(
      grepl(local_traces_pattern(), case$file),
      case$read,
      info = case$file
    )
  }
})

test_that("local trace files can follow a custom exporter template", {
  cases <- shared_fixture(file.path("trajectories", "otlp"))$exporter_template$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    path <- withr::local_tempdir()
    withr::local_envvar(
      OTEL_EXPORTER_OTLP_TRACES_FILE = file.path(path, case$template)
    )
    for (file in case$files) {
      writeLines(
        otlp_test_line(list(otlp_test_span("t1", file))),
        file.path(path, file)
      )
    }
    expect_equal(
      sort(vapply(
        read_local_spans(path),
        function(span) span$span_id,
        character(1)
      )),
      sort(as.character(unlist(case$read))),
      info = case$name
    )
  }
})

test_that("the latest chat span wins across timestamp digit counts", {
  expect_trajectory_member(build$latest_span)
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
  expect_trajectory_member(build$contentless, read = TRUE)
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
  expect_s7_class(.res[[1]]$turns[[1]], ellmer::UserTurn)
})

test_that("from/to filter conversations by chat-span start time", {
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  expect_trajectory_member(build$window, read = TRUE)
})

test_that("a conversation continuing past `to` returns history as of `to`", {
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  expect_trajectory_member(build$as_of, read = TRUE)
})

test_that("n keeps the most recent conversations", {
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  expect_trajectory_member(build$n, read = TRUE)
})

test_that("trajectory_read validates n, from, and to", {
  expect_snapshot(trajectory_read(n = 0), error = TRUE)
  expect_snapshot(trajectory_read(n = "x"), error = TRUE)
  expect_snapshot(trajectory_read(from = "not a date"), error = TRUE)
  expect_snapshot(trajectory_read(to = 1:2), error = TRUE)
  expect_snapshot(trajectory_read("dir", 5), error = TRUE)
})

test_that("Date and string window bounds mean local midnight", {
  expect_window_bound_member(build$local_midnight)
})

test_that("window bound strings must parse completely", {
  expect_window_bound_member(build$complete_parse)
})

connect_cases <- shared_fixture(file.path("trajectories", "connect-source"))

test_that("every member of trajectories/connect-source.json is run", {
  # A member that no test reads would pass silently.
  source <- paste(readLines(test_path("test-trajectories.R")), collapse = "\n")
  for (member in setdiff(names(connect_cases), "description")) {
    used <- paste0("connect_cases$", member, c(")", "$"))
    expect_true(
      any(vapply(used, grepl, logical(1), x = source, fixed = TRUE)),
      info = member
    )
  }
})

test_that("an empty Connect read diagnoses disabled tracing settings", {
  skip_on_cran()
  expect_connect_read_member(connect_cases$empty_read)

  client <- list(server = "https://connect.example.com", api_key = "key")
  content_enabled <- FALSE
  instrumentation_allowed <- TRUE
  httr2::local_mocked_responses(function(req) {
    path <- httr2::url_parse(req$url)$path
    body <- if (path == "/__api__/server_settings") {
      list(allow_content_instrumentation = instrumentation_allowed)
    } else {
      expect_equal(path, "/__api__/v1/content/guid")
      list(otel_enabled = content_enabled)
    }
    httr2::new_response(
      "GET",
      req$url,
      200L,
      list(`Content-Type` = "application/json"),
      charToRaw(jsonlite::toJSON(body, auto_unbox = TRUE)),
      request = req
    )
  })

  expect_snapshot(warn_if_connect_tracing_disabled(client, "guid"))

  content_enabled <- TRUE
  instrumentation_allowed <- FALSE
  expect_snapshot(warn_if_connect_tracing_disabled(client, "guid"))
})

test_that("a Connect read recovers a wrapper the `from` pushdown dropped", {
  expect_connect_read_member(connect_cases$refetch)
})

test_that("a windowed Connect read with intact ancestry fetches once", {
  expect_connect_read_member(connect_cases$fetch_once)
})

test_that("enough_trace_lines is satisfied once n conversations have content", {
  expect_enough_member(connect_cases$enough)
})

test_that("only ancestry below the turn wrapper counts as severed", {
  cases <- connect_cases$severed$cases
  expect_gt(length(cases), 0)
  for (case in cases) {
    spans <- parse_otlp_lines(connect_fixture_line(case[["spans"]]))
    expect_identical(
      has_severed_ancestry(spans),
      case[["expected"]],
      info = case[["name"]]
    )
  }
})

test_that("enough_trace_lines waits for a chat span's trailing wrapper", {
  expect_enough_member(connect_cases$enough_ancestry)
})

test_that("trajectory_read stops Connect paging after n conversations", {
  expect_connect_read_member(connect_cases$early_stop)
})

test_that("trajectory_read returns an empty list for a missing directory", {
  cases <- shared_fixture(file.path("trajectories", "otlp"))$missing_directory$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    path <- file.path(withr::local_tempdir(), case$path)
    if (case$file) {
      writeLines(otlp_test_line(list(otlp_test_span("t1", "s1"))), path)
    }
    expect_length(read_local_spans(path), 0)
    expect_length(trajectory_read(path), 0)
  }
})

test_that("trajectory_read validates source", {
  expect_snapshot(trajectory_read(1:2), error = TRUE)
})

test_that("a GUID source resolves to a Connect read", {
  expect_source_member(connect_cases$guid_source)
})

test_that("a GUID source finds its server in the environment, project, or rsconnect", {
  expect_source_member(connect_cases$guid_server)
})

test_that("a GUID source requires an unambiguous server", {
  withr::local_envvar(CONNECT_SERVER = NA, CONNECT_API_KEY = "key")
  withr::local_dir(withr::local_tempdir())
  local_mocked_bindings(
    registered_connect_servers = function() {
      c("https://one.example.com", "https://two.example.com")
    }
  )

  expect_snapshot(
    resolve_trajectory_source("ea3c1445-cb71-42df-a2f2-bdb18874ef41"),
    error = TRUE
  )
})

test_that("a content URL source carries its own server", {
  expect_source_member(connect_cases$content_url_source)
})

test_that("a dashboard URL source carries its own server", {
  expect_source_member(connect_cases$dashboard_url_source)
})

test_that("a vanity URL is resolved through Connect", {
  expect_source_member(connect_cases$vanity_source)
})

test_that("a vanity URL resolves against a configured Connect server", {
  url <- Sys.getenv("COMMONS_TEST_CONNECT_VANITY_URL")
  guid <- Sys.getenv("COMMONS_TEST_CONNECT_GUID")
  skip_if(!nzchar(url), "COMMONS_TEST_CONNECT_VANITY_URL is not set")
  skip_if(!nzchar(guid), "COMMONS_TEST_CONNECT_GUID is not set")
  skip_if(
    !nzchar(Sys.getenv("CONNECT_API_KEY")),
    "CONNECT_API_KEY is not set"
  )

  resolved <- resolve_trajectory_source(url)

  expect_equal(resolved$guid, guid)
})

test_that("a URL without a recognizable GUID errors rather than reading locally", {
  expect_source_member(connect_cases$unrecognized_url)

  expect_snapshot(
    resolve_trajectory_source("https://connect.example.com/other"),
    error = TRUE
  )
})

test_that("NULL source on Connect reads this content's traces", {
  expect_source_member(connect_cases$null_on_connect)
})

test_that("NULL source uses the project deployment record", {
  expect_source_member(connect_cases$null_deployment)
})

test_that("NULL source falls back to the local traces directory", {
  expect_source_member(connect_cases$null_local)

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
  cases <- shared_fixture(file.path("trajectories", "otlp"))$traces_dir$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    withr::local_envvar(
      OTEL_EXPORTER_OTLP_TRACES_FILE = case$exporter_file %||% NA,
      COMMONS_TRACES_DIR = case$commons_traces_dir %||% NA
    )
    if (!is.null(case$dir)) {
      expect_equal(local_traces_dir(), case$dir, info = case$name)
      next
    }
    # Windows unsets a variable set to "", so the case cannot be set up there.
    if (.Platform$OS.type == "windows") {
      next
    }
    withr::local_dir(withr::local_tempdir())
    writeLines(otlp_test_line(list(otlp_test_span("t1", "s1"))), "trace-1.jsonl")
    expect_length(read_local_spans(local_traces_dir()), 0)
  }
})

test_that("is_content_guid recognizes GUIDs", {
  cases <- connect_cases$content_guid$cases
  expect_gt(length(cases), 0)
  for (case in cases) {
    expect_identical(
      is_content_guid(case[["text"]]),
      case[["expected"]],
      info = case[["name"]]
    )
  }
})

test_that("content_url_guid extracts the server and GUID", {
  cases <- connect_cases$content_url$cases
  expect_gt(length(cases), 0)
  for (case in cases) {
    expect_identical(
      content_url_guid(case[["url"]]),
      case[["expected"]],
      info = case[["name"]]
    )
  }
})

test_that("content_vanity_url extracts the server and search query", {
  cases <- connect_cases$vanity_url$cases
  expect_gt(length(cases), 0)
  for (case in cases) {
    expect_identical(
      content_vanity_url(case[["url"]]),
      case[["expected"]],
      info = case[["name"]]
    )
  }
})

test_that("connect_window_param pads and formats the window bounds", {
  cases <- connect_cases$window_param$cases
  expect_gt(length(cases), 0)
  for (case in cases) {
    expect_identical(
      connect_window_param(.POSIXct(case[["at"]], tz = "UTC"), case[["pad"]]),
      case[["expected"]],
      info = case[["name"]]
    )
  }
})

test_that("deployment records are found in project subdirectories", {
  expect_deployment_member(connect_cases$record_search)
})

test_that("read_deployment_record skips records without a GUID", {
  expect_deployment_member(connect_cases$record_fields)
})

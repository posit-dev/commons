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

test_that("chat spans group by the nearest ancestor conversation id", {
  json <- test_turn_json()
  lines <- c(
    otlp_test_line(list(
      conversation_test_span("t1", "root1", "conv-a"),
      otlp_test_span("t1", "agent1", parent_span_id = "root1", name = "invoke_agent"),
      chat_test_span(
        "t1",
        "chat1",
        parent_span_id = "agent1",
        input_messages = '[{"role":"user","parts":[{"type":"text","content":"One."}]}]',
        end_time = "10"
      )
    )),
    otlp_test_line(list(
      conversation_test_span("t2", "root2", "conv-a"),
      otlp_test_span("t2", "agent2", parent_span_id = "root2", name = "invoke_agent"),
      chat_test_span(
        "t2",
        "chat2",
        parent_span_id = "agent2",
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

test_that("read_trajectories reads OTLP files from a directory", {
  path <- withr::local_tempdir()
  json <- test_turn_json()
  line <- otlp_test_line(list(
    chat_test_span("t1", "s1", input_messages = json$input)
  ))
  writeLines(line, file.path(path, "trace-0.jsonl"))
  writeLines(line, file.path(path, "trace-latest.jsonl"))

  trajectories <- read_trajectories(path)

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

test_that("read_trajectories hints when no conversation carries content", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  line <- otlp_test_line(list(
    chat_test_span("t1", "s1"),
    chat_test_span("t2", "s2")
  ))
  writeLines(line, file.path(path, "trace-0.jsonl"))

  expect_snapshot(.res <- read_trajectories(path))
  expect_length(.res, 0)
})

test_that("read_trajectories drops content-less conversations, keeping the rest", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  json <- test_turn_json()
  line <- otlp_test_line(list(
    chat_test_span("t1", "s1", input_messages = json$input),
    chat_test_span("t2", "s2")
  ))
  writeLines(line, file.path(path, "trace-0.jsonl"))

  expect_snapshot(.res <- read_trajectories(path))
  expect_length(.res, 1)
  expect_s7_class(.res[[1]][[1]], ellmer::UserTurn)
})

test_that("from/to filter conversations by chat-span start time", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  writeLines(staggered_test_line(), file.path(path, "trace-0.jsonl"))

  expect_named(
    read_trajectories(path, from = .POSIXct(200, tz = "UTC")),
    c("t200", "t300")
  )
  expect_named(
    read_trajectories(path, to = .POSIXct(200, tz = "UTC")),
    "t100"
  )
  expect_named(
    read_trajectories(
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

  full <- read_trajectories(path)
  as_of <- read_trajectories(path, to = .POSIXct(200, tz = "UTC"))

  expect_s7_class(full[[1]][[length(full[[1]])]], ellmer::AssistantTurn)
  expect_length(as_of[[1]], length(full[[1]]) - 1)
})

test_that("wrapper spans outside the window still group conversations", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  json <- test_turn_json()
  line <- otlp_test_line(list(
    conversation_test_span("t1", "root1", "conv-a"),
    chat_test_span(
      "t1",
      "chat1",
      parent_span_id = "root1",
      input_messages = json$input,
      start_time = "200000000000",
      end_time = "201000000000"
    )
  ))
  writeLines(line, file.path(path, "trace-0.jsonl"))

  trajectories <- read_trajectories(path, from = .POSIXct(150, tz = "UTC"))

  expect_named(trajectories, "conv-a")
})

test_that("n keeps the most recent conversations", {
  path <- withr::local_tempdir()
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  writeLines(staggered_test_line(), file.path(path, "trace-0.jsonl"))

  expect_named(read_trajectories(path, n = 2), c("t200", "t300"))
  expect_named(read_trajectories(path, n = 5), c("t100", "t200", "t300"))
  expect_named(
    read_trajectories(path, n = 1, from = .POSIXct(150, tz = "UTC")),
    "t300"
  )
})

test_that("read_trajectories validates n, from, and to", {
  expect_snapshot(read_trajectories(n = 0), error = TRUE)
  expect_snapshot(read_trajectories(n = "x"), error = TRUE)
  expect_snapshot(read_trajectories(from = "not a date"), error = TRUE)
  expect_snapshot(read_trajectories(to = 1:2), error = TRUE)
  expect_snapshot(read_trajectories("dir", 5), error = TRUE)
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
  wrapper <- conversation_test_span("t1", "root1", "conv-a")
  chat <- chat_test_span(
    "t1",
    "chat1",
    parent_span_id = "root1",
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

  trajectories <- read_trajectories(
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
        conversation_test_span("t1", "root1", "conv-a"),
        chat_test_span(
          "t1",
          "chat1",
          parent_span_id = "root1",
          input_messages = json$input,
          start_time = "200000000000",
          end_time = "201000000000"
        )
      ))
    }
  )

  trajectories <- read_trajectories(
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
    otlp_test_line(list(conversation_test_span("t1", "root1", "conv-a")))
  )

  enough <- enough_trace_lines(1, NULL, NULL)
  expect_false(enough(chat_only))
  expect_true(enough(with_wrapper))
})

test_that("read_trajectories stops Connect paging after n conversations", {
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

  trajectories <- read_trajectories(
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

test_that("read_trajectories returns an empty list for a missing directory", {
  expect_length(read_trajectories(file.path(tempdir(), "nope")), 0)
})

test_that("read_trajectories validates source", {
  expect_snapshot(read_trajectories(1:2), error = TRUE)
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

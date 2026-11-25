# The variables read, the server forms accepted and the URLs requests land on
# are shared with pkg-py; see tests/shared/connect.json.
connect_spec <- shared_fixture("connect")

test_that("the shared fixture carries the cases it promises", {
  detection <- vapply(
    connect_spec$runtime_detection$cases,
    function(case) case$expected,
    logical(1)
  )
  expect_setequal(detection, c(TRUE, FALSE))
  expect_gte(length(connect_spec$server_normalization$cases), 2)
  expect_gte(length(connect_spec$api_request$cases), 1)
  for (group in c("pages", "stores", "fallback", "access")) {
    expect_gt(length(connect_spec$traces[[group]]$cases), 0, label = group)
  }
  expect_gt(length(connect_spec$vanity_search$cases), 0)
})

test_that("connect_client normalizes the server URL", {
  env <- connect_spec$environment
  withr::local_envvar(structure(list("key"), names = env$api_key))

  for (case in connect_spec$server_normalization$cases) {
    client <- connect_client(server = case$configured)
    expect_equal(client$server, case$expected, info = case$name)
  }
})

test_that("connect_client errors without credentials", {
  withr::local_envvar(CONNECT_SERVER = NA, CONNECT_API_KEY = NA)
  expect_snapshot(connect_client(), error = TRUE)
  expect_snapshot(
    connect_client(server = "https://connect.example.com"),
    error = TRUE
  )
})

test_that("is_connect_runtime detects Connect env vars", {
  for (case in connect_spec$runtime_detection$cases) {
    values <- lapply(case$env, function(value) if (is.null(value)) NA else value)
    withr::with_envvar(values, {
      expect_equal(is_connect_runtime(), case$expected, info = case$name)
    })
  }
})

test_that("connect_req addresses the versioned API root", {
  client <- connect_client(
    server = connect_spec$api_request$server,
    api_key = "key"
  )

  for (case in connect_spec$api_request$cases) {
    req <- do.call(connect_req, c(list(client), case$path))
    expect_equal(req$url, case$expected, info = case$name)
  }
})

test_that("connect_vanity_guid matches the full vanity URL", {
  search <- connect_spec$vanity_search
  for (case in search$cases) {
    info <- case[["name"]]
    state <- new.env()
    httr2::local_mocked_responses(
      connect_fixture_responses(list(), state, search = case[["pages"]])
    )
    read <- function() {
      connect_vanity_guid(
        list(server = case[["server"]], api_key = "key"),
        paste0(case[["server"]], "/content/", case[["query"]]),
        case[["query"]]
      )
    }
    if (is.null(case[["expected"]])) {
      expect_error(read(), info = info)
    } else {
      expect_identical(read(), case[["expected"]], info = info)
    }
    queries <- lapply(state$requests, function(request) request[["query"]])
    expect_identical(
      vapply(queries, function(q) as.integer(q[["page_number"]]), integer(1)),
      as.integer(unlist(case[["page_numbers"]])),
      info = info
    )
    expect_identical(
      state$requests[[1]][["path"]],
      paste0(
        sub("/+$", "", httr2::url_parse(case[["server"]])$path %||% ""),
        "/__api__/v1/",
        paste(unlist(search$request$path), collapse = "/")
      ),
      info = info
    )
    first <- queries[[1]]
    expect_identical(first[["q"]], case[["query"]], info = info)
    for (key in names(search$request$query)) {
      expect_identical(first[[key]], search$request$query[[key]], info = info)
    }
  }
})

test_that("connect_vanity_guid explains an inaccessible URL", {
  httr2::local_mocked_responses(function(req) {
    httr2::new_response(
      "GET",
      req$url,
      200L,
      list(`Content-Type` = "application/json"),
      charToRaw(jsonlite::toJSON(
        list(
          results = list(),
          total = 0L
        ),
        auto_unbox = TRUE
      )),
      request = req
    )
  })

  expect_snapshot(
    connect_vanity_guid(
      list(server = "https://connect.example.com", api_key = "key"),
      "https://connect.example.com/content/missing",
      "missing"
    ),
    error = TRUE
  )
})

test_that("connect_trace_lines pages until the total is exhausted", {
  expect_trace_lines_member(connect_spec$traces$pages, connect_spec$traces)
})

test_that("connect_trace_lines reads collector and legacy stores", {
  expect_trace_lines_member(connect_spec$traces$stores, connect_spec$traces)
})

test_that("connect_trace_lines falls back when the content endpoint is absent", {
  expect_trace_lines_member(connect_spec$traces$fallback, connect_spec$traces)
})

test_that("parse_connect_version parses Connect version strings", {
  expect_equal(
    parse_connect_version("Posit Connect v2026.07.0"),
    numeric_version("2026.07.0")
  )
  expect_equal(
    parse_connect_version("2026.09.0"),
    numeric_version("2026.09.0")
  )
  expect_null(parse_connect_version("nginx"))
  expect_null(parse_connect_version(list()))
})

test_that("connect_trace_lines explains auth failures on the traces endpoint", {
  expect_trace_lines_member(connect_spec$traces$access, connect_spec$traces)

  httr2::local_mocked_responses(
    connect_fixture_responses(list(traces = list(status = 403)), new.env())
  )
  expect_snapshot(
    connect_trace_lines(
      list(server = "https://connect.example.com", api_key = "k"),
      "guid"
    ),
    error = TRUE
  )
})

test_that("connect_user_guid pages past the first page of prefix matches", {
  pages <- list(
    lapply(1:500, function(i) {
      list(username = paste0("jdoe", i), guid = paste0("g", i))
    }),
    list(list(username = "jdoe", guid = "guid-jdoe"))
  )
  local_mocked_bindings(
    connect_req = function(client, ...) structure(list(), class = "fake_req")
  )
  local_mocked_bindings(
    req_url_query = function(req, ..., page_number) page_number,
    req_perform = function(req, ...) req,
    resp_body_json = function(resp, ...) list(results = pages[[resp]]),
    .package = "httr2"
  )

  guid <- connect_user_guid(list(server = "s", api_key = "k"), "jdoe")

  expect_equal(guid, "guid-jdoe")
})

test_that("connect_user_guid errors when no user matches", {
  local_mocked_bindings(
    connect_req = function(client, ...) structure(list(), class = "fake_req")
  )
  local_mocked_bindings(
    req_url_query = function(req, ...) req,
    req_perform = function(req, ...) req,
    resp_body_json = function(resp, ...) list(results = list()),
    .package = "httr2"
  )

  expect_snapshot(
    connect_user_guid(list(server = "s", api_key = "k"), "jdoe"),
    error = TRUE
  )
})

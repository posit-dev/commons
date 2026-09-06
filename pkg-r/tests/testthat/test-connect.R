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
  httr2::local_mocked_responses(function(req) {
    url <- httr2::url_parse(req$url)
    expect_equal(url$path, "/__api__/v1/search/content")
    expect_equal(url$query$q, "my-agent")
    expect_equal(url$query$include, "vanity_url")
    httr2::new_response(
      "GET",
      req$url,
      200L,
      list(`Content-Type` = "application/json"),
      charToRaw(jsonlite::toJSON(
        list(
          results = list(
            list(
              guid = "wrong-guid",
              vanity_url = "https://connect.example.com/my-agent-test/"
            ),
            list(
              guid = "right-guid",
              vanity_url = "https://connect.example.com/my-agent/"
            )
          ),
          total = 1L
        ),
        auto_unbox = TRUE
      )),
      request = req
    )
  })

  guid <- connect_vanity_guid(
    list(server = "https://connect.example.com", api_key = "key"),
    "https://connect.example.com/content/my-agent",
    "my-agent"
  )

  expect_equal(guid, "right-guid")
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
          total = 1L
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
  pages <- list(
    c("line1", "line2"),
    "line3"
  )
  state <- new.env()
  state$calls <- 0
  local_mocked_bindings(
    connect_req = function(client, ...) structure(list(), class = "fake_req")
  )
  local_mocked_bindings(
    req_url_query = function(req, ...) req,
    req_perform = function(req, ...) {
      state$calls <- state$calls + 1
      state$calls
    },
    resp_has_body = function(resp) TRUE,
    resp_body_string = function(resp) {
      paste(pages[[resp]], collapse = "\n")
    },
    resp_header = function(resp, name) {
      if (name == "Server") "Posit Connect v2026.06.1" else "3"
    },
    .package = "httr2"
  )

  lines <- connect_trace_lines(list(server = "s", api_key = "k"), "guid")

  expect_equal(lines, c("line1", "line2", "line3"))
  expect_equal(state$calls, 2)
})

test_that("connect_trace_lines reads collector and legacy stores", {
  httr2::local_mocked_responses(function(req) {
    url <- req$url
    if (grepl("/jobs/job/traces", url, fixed = TRUE)) {
      return(httr2::new_response(
        "GET", url, 200L,
        list(`X-Total-Count` = "1"), charToRaw("legacy"), request = req
      ))
    }
    if (grepl("/jobs", url, fixed = TRUE)) {
      return(httr2::new_response(
        "GET", url, 200L,
        list(`Content-Type` = "application/json"),
        charToRaw('[{"key":"job"}]'),
        request = req
      ))
    }
    httr2::new_response(
      "GET", url, 200L,
      list(Server = "Posit Connect v2026.07.0", `X-Total-Count` = "1"),
      charToRaw("current"), request = req
    )
  })

  lines <- connect_trace_lines(
    list(server = "https://connect.example.com", api_key = "k"),
    "guid",
    enough = function(lines) TRUE
  )

  expect_equal(lines, c("current", "legacy"))
})

test_that("connect_trace_lines falls back when the content endpoint is absent", {
  local_mocked_bindings(connect_job_trace_lines = function(...) "legacy")
  httr2::local_mocked_responses(function(req) {
    httr2::new_response(
      "GET", req$url, 404L, list(), raw(), request = req
    )
  })

  lines <- connect_trace_lines(
    list(server = "https://connect.example.com", api_key = "k"), "guid"
  )

  expect_equal(lines, "legacy")
})

test_that("connect_server_version parses Connect response headers", {
  expect_equal(
    connect_server_version("Posit Connect v2026.07.0"),
    numeric_version("2026.07.0")
  )
  expect_null(connect_server_version("nginx"))
})

test_that("connect_trace_lines explains auth failures on the traces endpoint", {
  local_mocked_bindings(
    connect_req = function(client, ...) structure(list(), class = "fake_req")
  )
  local_mocked_bindings(
    req_url_query = function(req, ...) req,
    req_perform = function(req, ...) {
      rlang::abort("HTTP 403 Forbidden.", class = "httr2_http_403")
    },
    .package = "httr2"
  )

  expect_snapshot(
    connect_trace_lines(list(server = "s", api_key = "k"), "guid"),
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

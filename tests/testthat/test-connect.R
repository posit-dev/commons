test_that("connect_client normalizes the server URL", {
  withr::local_envvar(CONNECT_API_KEY = "key")

  client <- connect_client(server = "https://connect.example.com/")
  expect_equal(client$server, "https://connect.example.com")

  client <- connect_client(server = "https://connect.example.com/__api__")
  expect_equal(client$server, "https://connect.example.com")
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
  withr::local_envvar(POSIT_PRODUCT = NA, CONNECT_CONTENT_GUID = NA)
  expect_false(is_connect_runtime())

  withr::local_envvar(POSIT_PRODUCT = "CONNECT")
  expect_true(is_connect_runtime())

  withr::local_envvar(POSIT_PRODUCT = NA, CONNECT_CONTENT_GUID = "guid")
  expect_true(is_connect_runtime())
})

test_that("connect_trace_lines pages until the total is exhausted", {
  pages <- list(
    c("line1", "line2"),
    "line3"
  )
  calls <- 0
  local_mocked_bindings(
    connect_req = function(client, ...) structure(list(), class = "fake_req")
  )
  local_mocked_bindings(
    req_url_query = function(req, ...) req,
    req_perform = function(req, ...) {
      calls <<- calls + 1
      calls
    },
    resp_body_string = function(resp) {
      paste(pages[[resp]], collapse = "\n")
    },
    resp_header = function(resp, name) "3",
    .package = "httr2"
  )

  lines <- connect_trace_lines(list(server = "s", api_key = "k"), "guid")

  expect_equal(lines, c("line1", "line2", "line3"))
  expect_equal(calls, 2)
})

json_response <- function(req, body, status = 200L) {
  httr2::new_response(
    req$method %||% "GET",
    req$url,
    status,
    headers = list(`Content-Type` = "application/json"),
    body = charToRaw(jsonlite::toJSON(body, auto_unbox = TRUE))
  )
}

test_that("sharing is off outside Connect", {
  withr::local_envvar(POSIT_PRODUCT = NA, CONNECT_CONTENT_GUID = NA)
  session <- list(request = list(HTTP_POSIT_CONNECT_USER_SESSION_TOKEN = "t"))

  expect_null(share_server("chat", test_agent(), chat = NULL, session = session))
})

test_that("sharing uses a visitor key integration that can publish", {
  client <- list(server = "https://connect.example.com", api_key = "key")
  httr2::local_mocked_responses(function(req) {
    path <- httr2::url_parse(req$url)$path
    switch(
      path,
      "/__api__/v1/content/app/oauth/integrations/associations" = json_response(req, list(
        list(
          oauth_integration_guid = "snowflake",
          oauth_integration_template = "snowflake",
          oauth_integration_auth_type = "Viewer"
        ),
        list(
          oauth_integration_guid = "viewer-only",
          oauth_integration_template = "connect",
          oauth_integration_auth_type = "Visitor API Key"
        ),
        list(
          oauth_integration_guid = "publisher",
          oauth_integration_template = "connect",
          oauth_integration_auth_type = "Visitor API Key"
        )
      )),
      "/__api__/v1/oauth/integrations/viewer-only" = json_response(
        req,
        list(config = list(max_role = "Viewer"))
      ),
      "/__api__/v1/oauth/integrations/publisher" = json_response(
        req,
        list(config = list(max_role = "Publisher"))
      )
    )
  })

  expect_identical(connect_visitor_integration(client, "app"), "publisher")
  expect_null(connect_visitor_integration(client, ""))
})

test_that("a deploy is awaited past the moment its task is unknown", {
  client <- list(server = "https://connect.example.com", api_key = "key")
  polls <- 0
  httr2::local_mocked_responses(function(req) {
    polls <<- polls + 1
    if (polls == 1) {
      return(json_response(req, list(code = 4, error = "not found"), 404L))
    }
    json_response(req, list(finished = polls == 3, code = 0))
  })

  task <- sync_promise(connect_wait_task(client, "task"))

  expect_identical(polls, 3)
  expect_true(task$finished)
})

test_that("a failed deploy reports why in words a viewer can act on", {
  client <- list(server = "https://connect.example.com", api_key = "key")
  httr2::local_mocked_responses(function(req) {
    json_response(req, list(finished = TRUE, code = 1, error = "boom"))
  })

  err <- tryCatch(sync_promise(connect_wait_task(client, "task")), error = identity)

  expect_s3_class(err, "commons_share_error")
  expect_identical(share_error_message(err), share_error_messages$deploy)
  expect_identical(
    share_error_message(simpleError("HTTP 500")),
    "Couldn't share to Posit Connect. Try again."
  )
})

test_that("shared copies get titles Connect accepts", {
  expect_identical(share_title("Orders\nby region"), "Orders by region")
  expect_identical(share_title("Hi"), "Shared from commons")
  expect_identical(nchar(share_title(strrep("a", 2000))), 1024L)
})

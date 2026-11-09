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

test_that("receipts follow the conversation, not its turns", {
  id <- shiny::reactiveVal(NULL)
  hooks <- new.env()
  chat <- list(history = list(
    conversation_id = function() id(),
    on_restore = function(fn) hooks$restore <- fn,
    on_save = function(fn) hooks$save <- fn
  ))
  content <- list(guid = "g", content_url = "u", dashboard_url = "d")

  shiny::testServer(
    function(input, output, session) receipts <- share_receipts(chat),
    {
      id("a")
      session$flushReact()
      receipts$remember(list(key = "conversation", conversation = "a"), content)
      values <- hooks$save(list())
      expect_identical(values$commons_shares$conversation$guid, "g")

      # A share that finishes in another conversation isn't kept.
      receipts$remember(list(key = "document:x", conversation = "b"), content)
      expect_null(receipts$get("document:x"))

      id(NULL)
      session$flushReact()
      expect_null(receipts$get("conversation"))

      id("a")
      hooks$restore(values)
      session$flushReact()
      expect_identical(receipts$get("conversation")$guid, "g")
    }
  )
})

test_that("shared copies get titles Connect accepts", {
  expect_identical(share_title("Orders\nby region"), "Orders by region")
  expect_identical(share_title("Hi"), "Shared from commons")
  expect_identical(nchar(share_title(strrep("a", 2000))), 1024L)
})

test_that("a plot or table is found by the id its display carries", {
  agent <- test_agent()
  req <- ellmer::ContentToolRequest(
    id = "q1",
    name = "run_sql",
    arguments = list(sql = "SELECT region FROM sales")
  )
  html <- share_wrap("<table></table>", "table")
  agent$set_turns(list(
    ellmer::UserTurn(list(ellmer::ContentText("Which regions?"))),
    ellmer::AssistantTurn(list(req)),
    ellmer::UserTurn(list(ellmer::ContentToolResult(
      value = "region",
      request = req,
      extra = list(display = list(html = html))
    )))
  ))
  id <- regmatches(html, regexpr("[0-9a-f]{16}", html))

  target <- share_output_target(agent, id)

  expect_identical(target$kind, "output")
  expect_identical(target$key, paste0("output:", id))
  expect_identical(target$heading, "Share this table")
  expect_identical(target$title, "Which regions?")
  expect_identical(target$code, "commons$run_sql(\"SELECT region FROM sales\")")
  expect_null(share_output_target(agent, "0000"))
})

test_that("the dialog shows who can open the copy and how", {
  owner <- list(name = "Ada Lovelace", detail = "ada@example.com", guid = "u1")
  people <- list(list(name = "Grace", detail = "grace@example.com", guid = "u2"))

  html <- as.character(share_people_ui(owner, people, "remove"))
  expect_match(html, "Ada Lovelace (you)", fixed = TRUE)
  expect_match(html, "Owner", fixed = TRUE)
  expect_match(html, "data-guid=\"u2\"", fixed = TRUE)

  expect_match(
    as.character(share_access_note("restricted")),
    "Only people with access can open with the link.",
    fixed = TRUE
  )
  expect_match(
    as.character(share_access_note("app", "acl")),
    "People given access to the app later won't be added.",
    fixed = TRUE
  )
  expect_no_match(
    as.character(share_access_note("app", "logged_in")),
    "later",
    fixed = TRUE
  )

  waiting <- as.character(share_copy_button(NULL, "copy"))
  expect_match(waiting, "disabled", fixed = TRUE)
  ready <- as.character(share_copy_button("https://c.example.com/x/", "copy"))
  expect_match(ready, "data-url=\"https://c.example.com/x/\"", fixed = TRUE)
  expect_match(ready, "Copy link", fixed = TRUE)
})

test_that("receipts keep access choices and drop abandoned shares", {
  hooks <- new.env()
  chat <- list(history = list(
    conversation_id = function() "a",
    on_restore = function(fn) hooks$restore <- fn,
    on_save = function(fn) hooks$save <- fn
  ))
  target <- list(key = "output:x", conversation = "a")
  content <- list(guid = "g", content_url = "u", dashboard_url = "d")

  shiny::testServer(
    function(input, output, session) receipts <- share_receipts(chat),
    {
      receipts$remember(target, content)
      receipts$update(target, list(general = "app", inherited = list(u9 = "p1")))
      receipts$remember(target, content)
      expect_identical(receipts$get("output:x")$general, "app")
      expect_identical(receipts$get("output:x")$inherited, list(u9 = "p1"))

      receipts$forget(target)
      expect_null(receipts$get("output:x"))
    }
  )
})

test_that("people search lists users and groups together", {
  client <- list(server = "https://connect.example.com", api_key = "key")
  httr2::local_mocked_responses(function(req) {
    switch(
      httr2::url_parse(req$url)$path,
      "/__api__/v1/users" = json_response(req, list(results = list(
        list(guid = "u1", username = "ada", first_name = "Ada", last_name = "L", email = "ada@x.com"),
        list(guid = "u2", username = "bob", first_name = "", last_name = "")
      ))),
      "/__api__/v1/groups" = json_response(req, list(results = list(
        list(guid = "g1", name = "Analysts")
      )))
    )
  })

  found <- sync_promise(connect_search_principals(client, "a"))

  expect_identical(vapply(found, `[[`, "", "name"), c("Ada L", "bob", "Analysts"))
  expect_identical(vapply(found, `[[`, "", "type"), c("user", "user", "group"))
})

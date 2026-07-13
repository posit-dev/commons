test_that("log_local validates its path", {
  expect_error(log_local(c("a", "b")), "single directory path")
})

test_that("log_pins validates share_with", {
  expect_error(log_pins(share_with = 1), "character vector")
})

test_that("normalize_log_spec maps shorthands to specs", {
  expect_equal(normalize_log_spec(FALSE)$kind, "off")
  expect_equal(normalize_log_spec(NULL)$kind, "off")
  expect_equal(normalize_log_spec(TRUE)$kind, "auto")

  spec <- normalize_log_spec("/tmp/logs")
  expect_equal(spec$kind, "local")
  expect_equal(spec$path, "/tmp/logs")

  expect_error(normalize_log_spec(1:2), "must be")
})

test_that("log_pins forwards share_with to the pin logger on Connect", {
  captured <- NULL
  local_mocked_bindings(
    is_connect_runtime = function() TRUE,
    new_pin_logger = function(conversation_id, share_with = NULL) {
      captured <<- share_with
      new_noop_logger()
    }
  )

  new_trajectory_logger(log_pins(share_with = c("jdoe", "asmith")))

  expect_equal(captured, c("jdoe", "asmith"))
})

test_that("log_pins warns and logs locally when not on Connect", {
  local_mocked_bindings(is_connect_runtime = function() FALSE)

  expect_warning(
    logger <- new_trajectory_logger(log_pins(share_with = "jdoe")),
    "only applies when logging to Connect pins"
  )
  expect_false(is.na(logger$conversation_id))
})

test_that("the sharer is a no-op when share_with is empty", {
  called <- FALSE
  local_mocked_bindings(
    share_trajectory_pin = function(...) called <<- TRUE
  )

  share <- new_trajectory_sharer(NULL, NULL)
  share(name = "commons-trajectory-x")

  expect_false(called)
})

test_that("the sharer grants access once across repeated writes", {
  skip_if_not_installed("connectapi")

  calls <- 0L
  local_mocked_bindings(
    share_trajectory_pin = function(...) calls <<- calls + 1L
  )

  share <- new_trajectory_sharer(NULL, c("jdoe", "asmith"))
  share(name = "commons-trajectory-x")
  share(name = "commons-trajectory-x")
  share(name = "commons-trajectory-x")

  expect_equal(calls, 1L)
})

test_that("the sharer warns once but keeps retrying when granting fails", {
  skip_if_not_installed("connectapi")

  calls <- 0L
  local_mocked_bindings(
    share_trajectory_pin = function(...) {
      calls <<- calls + 1L
      rlang::abort("nope")
    }
  )

  share <- new_trajectory_sharer(NULL, "jdoe")
  expect_warning(
    share(name = "commons-trajectory-x"),
    "Could not share the trajectory pin"
  )
  expect_no_warning(share(name = "commons-trajectory-x"))
  expect_equal(calls, 2L)
})

test_that("share_trajectory_pin grants viewer access without sending email", {
  skip_if_not_installed("connectapi")

  posts <- list()
  resolved_guid <- NULL
  connect <- list(
    POST = function(path, body, ...) {
      posts[[length(posts) + 1]] <<- list(path = path, body = body)
      NULL
    }
  )
  local_mocked_bindings(
    pin_meta = function(board, name, ...) list(local = list(content_id = "content-guid")),
    .package = "pins"
  )
  local_mocked_bindings(
    connect = function(...) "client",
    user_guid_from_username = function(client, username) paste0("guid-", username),
    content_item = function(client, guid) {
      resolved_guid <<- guid
      list(
        get_connect = function() connect,
        get_content = function() list(guid = guid)
      )
    },
    .package = "connectapi"
  )

  share_trajectory_pin(list(account = "u"), "commons-trajectory-x", c("jdoe", "asmith"))

  expect_equal(resolved_guid, "content-guid")
  expect_equal(vapply(posts, function(p) p$body$principal_guid, character(1)),
    c("guid-jdoe", "guid-asmith"))
  expect_true(all(vapply(posts, function(p) p$path, character(1)) ==
    "v1/content/content-guid/permissions"))
  expect_true(all(vapply(posts, function(p) p$body$role, character(1)) == "viewer"))
  expect_true(all(vapply(posts, function(p) isFALSE(p$body$send_email), logical(1))))
})

test_that("connect_pin_name qualifies bare names with the board account", {
  expect_equal(
    connect_pin_name(list(account = "jdoe"), "commons-trajectory-x"),
    "jdoe/commons-trajectory-x"
  )
  # Already qualified, or no account available: left as-is.
  expect_equal(
    connect_pin_name(list(account = "jdoe"), "jdoe/commons-trajectory-x"),
    "jdoe/commons-trajectory-x"
  )
  expect_equal(
    connect_pin_name(list(account = NULL), "commons-trajectory-x"),
    "commons-trajectory-x"
  )
})

test_that("trajectory_content_item errors when the content GUID can't be resolved", {
  skip_if_not_installed("connectapi")

  local_mocked_bindings(
    pin_meta = function(board, name, ...) list(local = list(content_id = NULL)),
    .package = "pins"
  )

  expect_error(
    trajectory_content_item("client", list(account = "u"), "missing-pin"),
    "Could not resolve the Connect content GUID"
  )
})

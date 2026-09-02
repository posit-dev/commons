test_that("new_trajectory_tracing validates its inputs", {
  expect_snapshot(new_trajectory_tracing(TRUE, share_with = 1), error = TRUE)
})

test_that("log = FALSE disables tracing", {
  withr::local_envvar(
    CONNECT_CONTENT_GUID = "guid",
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = NA
  )
  checked_connect <- FALSE
  local_mocked_bindings(
    warn_if_connect_tracing_unsupported = function() {
      checked_connect <<- TRUE
    }
  )
  expect_false(new_trajectory_tracing(FALSE))
  expect_false(checked_connect)
})

test_that("share_with warns and is ignored when log = FALSE", {
  expect_snapshot(.res <- new_trajectory_tracing(FALSE, share_with = "jdoe"))
  expect_false(.res)
})

test_that("log = TRUE warns without the otel package", {
  local_mocked_bindings(is_installed = function(pkg) FALSE)
  expect_snapshot(.res <- new_trajectory_tracing(TRUE))
  expect_false(.res)
})

test_that("the Connect tracing warning checks version before settings", {
  skip_on_cran()
  withr::local_envvar(
    CONNECT_SERVER = "https://connect.example.com",
    CONNECT_API_KEY = "key",
    CONNECT_CONTENT_GUID = "guid"
  )
  settings <- list(
    version = "2026.08.0",
    allow_content_instrumentation = FALSE
  )
  httr2::local_mocked_responses(function(req) {
    expect_equal(httr2::url_parse(req$url)$path, "/__api__/server_settings")
    if (inherits(settings, "condition")) {
      return(httr2::new_response(
        "GET",
        req$url,
        500L,
        list(),
        raw(),
        request = req
      ))
    }
    httr2::new_response(
      "GET",
      req$url,
      200L,
      list(`Content-Type` = "application/json"),
      charToRaw(jsonlite::toJSON(settings, auto_unbox = TRUE)),
      request = req
    )
  })

  expect_snapshot(warn_if_connect_tracing_unsupported())
  settings$version <- "2026.09.0"
  expect_snapshot(warn_if_connect_tracing_unsupported())

  settings$allow_content_instrumentation <- TRUE
  expect_no_warning(warn_if_connect_tracing_unsupported())

  settings <- list()
  expect_no_warning(warn_if_connect_tracing_unsupported())

  settings <- "unexpected response"
  expect_no_warning(warn_if_connect_tracing_unsupported())

  settings <- rlang::error_cnd("unavailable")
  expect_no_warning(warn_if_connect_tracing_unsupported())
})

test_that("the content-capture deployment warning is limited to Connect", {
  withr::local_envvar(
    POSIT_PRODUCT = NA,
    CONNECT_CONTENT_GUID = NA,
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = NA
  )
  expect_no_warning(warn_if_content_capture_not_deployed())

  withr::local_envvar(CONNECT_CONTENT_GUID = "guid")
  expect_snapshot(warn_if_content_capture_not_deployed())

  withr::local_envvar(
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true"
  )
  expect_no_warning(warn_if_content_capture_not_deployed())
})

test_that("log = TRUE stays quiet when tracing is disabled locally", {
  skip_if_not_installed("otel")
  withr::local_envvar(
    POSIT_PRODUCT = NA,
    CONNECT_CONTENT_GUID = NA,
    COMMONS_TRACES_DIR = "/tmp/commons-traces"
  )

  expect_no_warning(.res <- new_trajectory_tracing(TRUE))
  expect_false(.res)
})

test_that("log = TRUE points at Content Observability on Connect", {
  skip_if_not_installed("otel")
  withr::local_envvar(
    CONNECT_CONTENT_GUID = "guid",
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true"
  )
  clear_observability_attempted()
  local_mocked_bindings(
    connect_client = function(...) rlang::abort("no api key")
  )

  expect_snapshot(.res <- new_trajectory_tracing(TRUE))
  expect_false(.res)
})

test_that("tracing disabled on Connect flips the observability setting on", {
  skip_if_not_installed("otel")
  withr::local_envvar(
    CONNECT_CONTENT_GUID = "guid",
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true"
  )
  clear_observability_attempted()
  state <- new.env()
  state$patched <- 0
  local_mocked_bindings(
    connect_client = function(...) list(server = "s", api_key = "k"),
    connect_content = function(client, guid) list(otel_enabled = FALSE),
    connect_enable_otel = function(client, guid) {
      state$patched <- state$patched + 1
      invisible(NULL)
    }
  )

  expect_snapshot(.res <- new_trajectory_tracing(TRUE))
  expect_false(.res)
  expect_equal(state$patched, 1)

  # Later constructions in the same process skip the API calls.
  expect_no_warning(.res <- new_trajectory_tracing(TRUE))
  expect_equal(state$patched, 1)
})

test_that("an already-on observability setting warns about the restart", {
  skip_if_not_installed("otel")
  withr::local_envvar(
    CONNECT_CONTENT_GUID = "guid",
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true"
  )
  clear_observability_attempted()
  state <- new.env()
  state$patched <- 0
  local_mocked_bindings(
    connect_client = function(...) list(server = "s", api_key = "k"),
    connect_content = function(client, guid) list(otel_enabled = TRUE),
    connect_enable_otel = function(client, guid) {
      state$patched <- state$patched + 1
      invisible(NULL)
    }
  )

  expect_snapshot(.res <- new_trajectory_tracing(TRUE))
  expect_false(.res)
  expect_equal(state$patched, 0)
})

test_that("traces directory can come from COMMONS_TRACES_DIR", {
  withr::local_envvar(COMMONS_TRACES_DIR = NA)
  expect_equal(commons_traces_dir(), file.path(tempdir(), "commons-traces"))

  withr::local_envvar(COMMONS_TRACES_DIR = "/some/dir")
  expect_equal(commons_traces_dir(), "/some/dir")
})

test_that("local_conversation_turn_span is a no-op without tracing", {
  skip_if_not_installed("otel")
  expect_null(local_conversation_turn_span())
})

test_that("share_trajectory_access warns off Connect", {
  withr::local_envvar(POSIT_PRODUCT = NA, CONNECT_CONTENT_GUID = NA)
  expect_snapshot(share_trajectory_access("jdoe"))
})

# Who gets a grant, and what the grant says, are shared with pkg-py; see
# tests/shared/connect.json.
test_that("share_trajectory_access grants who the shared fixture says", {
  spec <- shared_fixture("connect")$sharing
  expect_setequal(
    vapply(spec$cases, function(case) length(case$expected) > 0, logical(1)),
    c(TRUE, FALSE)
  )

  for (case in spec$cases) {
    withr::local_envvar(CONNECT_CONTENT_GUID = "content-guid")
    clear_granted_access()
    state <- new.env()
    state$added <- character()
    permitted <- vapply(
      Filter(function(perm) perm$role == "owner", case$permitted),
      function(perm) perm$principal_guid,
      character(1)
    )
    local_mocked_bindings(
      connect_client = function(...) list(server = "s", api_key = "k"),
      connect_collaborator_principals = function(client, guid) permitted,
      connect_user_guid = function(client, username, ...) {
        paste0("guid-", tolower(username))
      },
      connect_add_collaborator = function(client, guid, principal_guid) {
        state$added <- c(state$added, principal_guid)
        invisible(NULL)
      }
    )

    share_trajectory_access(unlist(case$usernames))

    expect_equal(
      state$added,
      unlist(case$expected) %||% character(),
      info = case$name
    )
  }
})

test_that("connect_add_collaborator sends the shared grant body", {
  spec <- shared_fixture("connect")$collaborator_grant
  sent <- NULL
  httr2::local_mocked_responses(function(req) {
    sent <<- req
    httr2::new_response("POST", req$url, 200L, list(), raw(), request = req)
  })

  connect_add_collaborator(
    list(server = "https://connect.example.com", api_key = "k"),
    "content-guid",
    "guid-jdoe"
  )

  # httr2 infers POST from the presence of a body rather than recording it.
  expect_equal(sent$method %||% "POST", spec$method)
  expect_equal(
    sent$url,
    paste(
      c(
        "https://connect.example.com/__api__/v1",
        vapply(spec$endpoint, function(part) {
          sub("{guid}", "content-guid", part, fixed = TRUE)
        }, character(1))
      ),
      collapse = "/"
    )
  )
  body <- sent$body$data
  expect_equal(body[names(spec$body)], spec$body)
  expect_equal(body$principal_guid, "guid-jdoe")
})

test_that("share_trajectory_access looks a repeated username up once", {
  withr::local_envvar(CONNECT_CONTENT_GUID = "content-guid")
  clear_granted_access()
  state <- new.env()
  state$lookups <- 0
  local_mocked_bindings(
    connect_client = function(...) list(server = "s", api_key = "k"),
    connect_collaborator_principals = function(client, guid) character(),
    connect_user_guid = function(client, username, ...) {
      state$lookups <- state$lookups + 1
      paste0("guid-", tolower(username))
    },
    connect_add_collaborator = function(client, guid, principal_guid) {
      invisible(NULL)
    }
  )

  share_trajectory_access(c("jdoe", "JDOE"))

  expect_equal(state$lookups, 1)
})

test_that("share_trajectory_access skips usernames already handled", {
  withr::local_envvar(CONNECT_CONTENT_GUID = "content-guid")
  clear_granted_access()
  state <- new.env()
  state$lookups <- 0
  local_mocked_bindings(
    connect_client = function(...) list(server = "s", api_key = "k"),
    connect_collaborator_principals = function(client, guid) character(),
    connect_user_guid = function(client, username, ...) {
      state$lookups <- state$lookups + 1
      paste0("guid-", username)
    },
    connect_add_collaborator = function(client, guid, principal_guid) {
      invisible(NULL)
    }
  )

  share_trajectory_access("jdoe")
  share_trajectory_access("jdoe")

  expect_equal(state$lookups, 1)
})

test_that("share_trajectory_access warns rather than errors on failure", {
  withr::local_envvar(CONNECT_CONTENT_GUID = "content-guid")
  clear_granted_access()
  local_mocked_bindings(
    connect_client = function(...) rlang::abort("no api key")
  )

  expect_snapshot(share_trajectory_access("jdoe"))
})

test_that("content_capture_enabled matches the shared capture cases", {
  spec <- shared_fixture("traces")$content_capture
  expect_gt(length(spec$cases), 0)
  # Registered first, so it runs last: re-cache ellmer's capture flag once
  # every case's variable is restored.
  withr::defer(refresh_ellmer_otel_cache())

  for (case in spec$cases) {
    withr::local_envvar(
      stats::setNames(case$value %||% NA_character_, spec$variable)
    )
    expect_no_warning(enabled <- content_capture_enabled())
    expect_identical(enabled, case$enabled, info = case$name)
    expect_identical(Sys.getenv(spec$variable), case$after, info = case$name)
  }
})

test_that("missing content capture uses the ellmer fallback", {
  withr::local_envvar(OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = NA)
  refreshed <- FALSE
  local_mocked_bindings(
    refresh_ellmer_otel_cache = function() {
      refreshed <<- TRUE
      TRUE
    }
  )

  expect_no_warning(.res <- content_capture_enabled())
  expect_true(.res)
  expect_true(refreshed)
  expect_equal(
    Sys.getenv("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"),
    "true"
  )
})

test_that("a missing ellmer fallback leaves content capture disabled", {
  withr::local_envvar(OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = NA)
  local_mocked_bindings(refresh_ellmer_otel_cache = function() FALSE)

  expect_no_warning(.res <- content_capture_enabled())
  expect_false(.res)
  expect_identical(
    Sys.getenv("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"),
    ""
  )
})

test_that("the ellmer content-capture fallback still exists", {
  skip_on_cran()
  expect_true(is.function(asNamespace("ellmer")[["otel_cache_tracer"]]))
})

test_that("share_with grants wait for tracing to be live", {
  skip_if_not_installed("otel")
  withr::local_envvar(CONNECT_CONTENT_GUID = "guid")
  state <- new.env()
  state$shared <- FALSE
  local_mocked_bindings(
    enable_content_observability = function() NULL,
    share_trajectory_access = function(share_with) state$shared <- TRUE
  )

  suppressWarnings(.res <- new_trajectory_tracing(TRUE, share_with = "jdoe"))

  expect_false(.res)
  expect_false(state$shared)
})

test_that("local_commons_span is a no-op without otel", {
  local_mocked_bindings(is_installed = function(pkg) FALSE)
  expect_null(local_commons_span("commons_test_span"))
})

test_that("local_commons_span records a span with attributes", {
  skip_if_not_installed("otelsdk")

  recorded <- otelsdk::with_otel_record({
    fn <- function() {
      local_commons_span(
        "commons_test_span",
        attributes = list("commons.test.value" = 1L)
      )
      invisible(NULL)
    }
    fn()
  })

  spans <- recorded$traces
  expect_length(spans, 1)
  expect_equal(spans[[1]]$name, "commons_test_span")
  expect_equal(spans[[1]]$attributes[["commons.test.value"]], 1L)
})

test_that("commons_span_set_attribute no-ops when span is NULL", {
  expect_null(commons_span_set_attribute(NULL, "commons.test.value", 1L))
})

test_that("conversation turn spans are recorded", {
  skip_if_not_installed("otelsdk")

  recorded <- otelsdk::with_otel_record({
    turn <- function() {
      local_conversation_turn_span()
      invisible(NULL)
    }
    turn()
  })

  spans <- recorded$traces
  expect_length(spans, 1)
  expect_equal(spans[[1]]$name, "commons_conversation_turn")
  expect_null(spans[[1]]$attributes[["commons.connect.user"]])
})

test_that("trajectory users come only from authenticated session identity", {
  expect_identical(trajectory_user(NULL), NA_character_)
  for (user in list(NULL, "", NA_character_, c("alice", "bob"), 1)) {
    expect_identical(trajectory_user(list(user = user)), NA_character_)
  }
  expect_identical(trajectory_user(list(user = "alice")), "alice")
})

test_that("conversation turn spans capture the active session user", {
  skip_if_not_installed("otelsdk")
  skip_if_not_installed("shiny")
  alice <- shiny::MockShinySession$new()
  bob <- shiny::MockShinySession$new()
  withr::defer(alice$close())
  withr::defer(bob$close())
  alice$user <- "alice"
  bob$user <- "bob"

  recorded <- otelsdk::with_otel_record({
    turn <- function() {
      local_conversation_turn_span()
      invisible(NULL)
    }
    shiny::withReactiveDomain(alice, turn())
    shiny::withReactiveDomain(bob, turn())
    turn()
  })

  expect_length(recorded$traces, 3)
  expect_identical(
    recorded$traces[[1]]$attributes[["commons.connect.user"]],
    "alice"
  )
  expect_identical(
    recorded$traces[[2]]$attributes[["commons.connect.user"]],
    "bob"
  )
  expect_null(recorded$traces[[3]]$attributes[["commons.connect.user"]])
})

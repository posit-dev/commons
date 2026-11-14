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

# What the server warning checks, and in which order, is shared with pkg-py;
# see tests/shared/connect.json. The warning text is snapshotted below.
local_connect_settings <- function(settings, env = parent.frame()) {
  withr::local_envvar(
    CONNECT_SERVER = "https://connect.example.com",
    CONNECT_API_KEY = "key",
    CONNECT_CONTENT_GUID = "guid",
    .local_envir = env
  )
  httr2::local_mocked_responses(
    function(req) {
      expect_equal(req$url, "https://connect.example.com/__api__/server_settings")
      if (is.null(settings)) {
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
    },
    env = env
  )
}

test_that("the Connect tracing warning follows the shared cases", {
  skip_on_cran()
  observability <- shared_fixture("connect")$observability
  spec <- observability$server_settings
  expect_gt(length(spec$cases), 0)
  expect_equal(
    parse_connect_version(observability$minimum_version),
    numeric_version("2026.09.0")
  )
  patterns <- c(
    version = "requires Connect >= 2026.09.0",
    disabled = "disabled by this Posit Connect server"
  )

  for (case in spec$cases) {
    local_connect_settings(case$settings)
    if (is.null(case$warns)) {
      expect_no_warning(warn_if_connect_tracing_unsupported())
    } else {
      expect_warning(
        warn_if_connect_tracing_unsupported(),
        patterns[[case$warns]],
        info = case$name
      )
    }
  }
})

test_that("the Connect tracing warning checks version before settings", {
  skip_on_cran()
  local_connect_settings(list(
    version = "2026.08.0",
    allow_content_instrumentation = FALSE
  ))
  expect_snapshot(warn_if_connect_tracing_unsupported())
  local_connect_settings(list(
    version = "2026.09.0",
    allow_content_instrumentation = FALSE
  ))
  expect_snapshot(warn_if_connect_tracing_unsupported())
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

# The requests themselves are shared with pkg-py; see tests/shared/connect.json.
test_that("the observability requests match the shared fixture", {
  spec <- shared_fixture("connect")$observability
  client <- list(server = "https://connect.example.com", api_key = "k")
  seen <- list()
  httr2::local_mocked_responses(function(req) {
    seen[[length(seen) + 1]] <<- req
    httr2::new_response(
      "GET",
      req$url,
      200L,
      list(`Content-Type` = "application/json"),
      charToRaw("{}"),
      request = req
    )
  })
  endpoint <- function(parts) {
    vapply(parts, sub, character(1), pattern = "{guid}", replacement = "g",
           fixed = TRUE)
  }

  connect_server_settings(client)
  expect_equal(
    seen[[1]]$url,
    sub("{server}", client$server, spec$server_settings$url, fixed = TRUE)
  )
  expect_equal(seen[[1]]$method %||% "GET", spec$server_settings$method)

  connect_content(client, "g")
  expect_equal(
    seen[[2]]$url,
    paste(
      c(paste0(client$server, "/__api__/v1"), endpoint(spec$enable$read$endpoint)),
      collapse = "/"
    )
  )
  expect_equal(seen[[2]]$method %||% "GET", spec$enable$read$method)

  connect_enable_otel(client, "g")
  expect_equal(
    seen[[3]]$url,
    paste(
      c(paste0(client$server, "/__api__/v1"), endpoint(spec$enable$write$endpoint)),
      collapse = "/"
    )
  )
  expect_equal(seen[[3]]$method, spec$enable$write$method)
  expect_equal(seen[[3]]$body$data, spec$enable$write$body)
})

test_that("content observability enablement follows the shared cases", {
  withr::local_envvar(CONNECT_CONTENT_GUID = "guid")
  patterns <- c(
    toggled = "Enabled Content Observability for this content",
    already_on = "Content Observability is enabled for this content",
    failed = "OpenTelemetry tracing is not active"
  )

  cases <- shared_fixture("connect")$observability$enable$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    clear_observability_attempted()
    state <- new.env()
    state$patched <- 0
    local_mocked_bindings(
      connect_client = function(...) list(server = "s", api_key = "k"),
      connect_content = function(client, guid) {
        if (is.null(case$content)) rlang::abort("read failed")
        case$content
      },
      connect_enable_otel = function(client, guid) {
        state$patched <- state$patched + 1
        if (isTRUE(case$patch_fails)) rlang::abort("write failed")
        invisible(NULL)
      }
    )

    expect_warning(
      enable_content_observability(),
      patterns[[case$outcome]],
      info = case$name
    )
    expect_equal(state$patched, as.numeric(case$patched), info = case$name)
  }
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

# A Connect server for the shared sharing cases. Username `x` resolves to
# `guid-x` unless it is in `case$unknown`, and a grant for a principal in
# `state$refused` gets a 400; it starts as `case$refused`. `state` records the
# grants that went through and the usernames looked up.
local_connect_double <- function(case, state, env = parent.frame()) {
  withr::local_envvar(
    CONNECT_CONTENT_GUID = "content-guid",
    CONNECT_SERVER = "https://connect.example.com",
    CONNECT_API_KEY = "k",
    .local_envir = env
  )
  state$added <- character()
  state$looked_up <- character()
  state$refused <- unlist(case$refused)
  json_response <- function(req, body) {
    httr2::new_response(
      "GET", req$url, 200L,
      list(`Content-Type` = "application/json"),
      charToRaw(jsonlite::toJSON(body, auto_unbox = TRUE)),
      request = req
    )
  }
  httr2::local_mocked_responses(
    function(req) {
      if (!is.null(req$body)) {
        principal <- req$body$data$principal_guid
        if (principal %in% state$refused) {
          return(httr2::response(400L, request = req))
        }
        state$added <- c(state$added, principal)
        return(json_response(req, structure(list(), names = character())))
      }
      if (grepl("/permissions$", req$url)) {
        return(json_response(req, case$permitted %||% list()))
      }
      prefix <- httr2::url_parse(req$url)$query$prefix
      state$looked_up <- c(state$looked_up, prefix)
      if (prefix %in% unlist(case$unknown)) {
        return(json_response(req, list(results = list())))
      }
      json_response(req, list(results = list(
        list(username = prefix, guid = paste0("guid-", prefix))
      )))
    },
    env = env
  )
}

# Who gets a grant, what the grant says, and what a second share looks up are
# shared with pkg-py; see tests/shared/connect.json.
test_that("share_trajectory_access grants who the shared fixture says", {
  spec <- shared_fixture("connect")$sharing
  expect_setequal(
    vapply(spec$cases, function(case) length(case$expected) > 0, logical(1)),
    c(TRUE, FALSE)
  )

  for (case in spec$cases) {
    clear_granted_access()
    state <- new.env()
    local_connect_double(case, state)

    if (isTRUE(case$warns)) {
      expect_warning(
        share_trajectory_access(unlist(case$usernames)),
        "Could not share"
      )
    } else {
      expect_no_warning(share_trajectory_access(unlist(case$usernames)))
    }

    expect_equal(
      state$added,
      unlist(case$expected) %||% character(),
      info = case$name
    )
  }
})

test_that("a second share looks up who the shared fixture says", {
  for (case in shared_fixture("connect")$sharing_again$cases) {
    clear_granted_access()
    state <- new.env()
    local_connect_double(case, state)

    suppressWarnings(share_trajectory_access(unlist(case$usernames)))
    state$looked_up <- character()
    state$added <- character()
    state$refused <- character()
    expect_no_warning(share_trajectory_access(unlist(case$again)))

    expect_equal(
      state$looked_up,
      unlist(case$looked_up) %||% character(),
      info = case$name
    )
    expect_equal(
      state$added,
      unlist(case$granted) %||% character(),
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
  contract <- shared_fixture("traces")$conversation_turn

  recorded <- otelsdk::with_otel_record({
    turn <- function() {
      local_conversation_turn_span()
      invisible(NULL)
    }
    turn()
  })

  spans <- recorded$traces
  expect_length(spans, 1)
  expect_equal(spans[[1]]$name, contract$span)
  expect_null(spans[[1]]$attributes[[contract$user_attribute]])
})

test_that("trajectory users follow the shared user cases", {
  cases <- shared_fixture("traces")$conversation_turn$user_cases
  expect_gt(length(cases), 0)
  for (case in cases) {
    session <- if (isTRUE(case$module)) {
      skip_if_not_installed("shiny")
      root <- shiny::MockShinySession$new()
      withr::defer(root$close())
      root$user <- case$session_user
      root$makeScope("module")
    } else if (!identical(case$session, FALSE)) {
      list(user = unlist(case$session_user))
    }
    expected <- case$recorded %||% NA_character_
    expect_identical(trajectory_user(session), expected, label = case$name)
  }
})

test_that("trajectory users reject a missing value", {
  expect_identical(trajectory_user(list(user = NA_character_)), NA_character_)
})

test_that("conversation turn spans capture the active session user", {
  skip_if_not_installed("otelsdk")
  skip_if_not_installed("shiny")
  attribute <- shared_fixture("traces")$conversation_turn$user_attribute
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
    recorded$traces[[1]]$attributes[[attribute]],
    "alice"
  )
  expect_identical(
    recorded$traces[[2]]$attributes[[attribute]],
    "bob"
  )
  expect_null(recorded$traces[[3]]$attributes[[attribute]])
})

test_that("provenance spans follow the shared candidates cases", {
  skip_if_not_installed("otelsdk")
  contract <- shared_fixture("traces")$provenance
  expect_gt(length(contract$candidates_cases), 0)

  for (case in contract$candidates_cases) {
    decisions <- lapply(case$decisions, function(decision) {
      decision$quote <- decision$quote %||% NA_character_
      decision
    })
    recorded <- otelsdk::with_otel_record({
      record_provenance_span("B", decisions)
    })

    span <- recorded$traces[[1]]
    expect_equal(span$name, contract$span, label = case$name)
    expect_setequal(
      names(span$attributes),
      c(contract$tag_attribute, contract$candidates_attribute)
    )
    expect_equal(
      jsonlite::fromJSON(
        span$attributes[[contract$candidates_attribute]],
        simplifyVector = FALSE
      ),
      case$expected,
      label = case$name
    )
  }
})

test_that("provenance spans follow the shared tag cases", {
  skip_if_not_installed("otelsdk")
  contract <- shared_fixture("traces")$provenance
  expect_gt(length(contract$tag_cases), 0)

  for (case in contract$tag_cases) {
    recorded <- otelsdk::with_otel_record({
      record_provenance_span(case$tag %||% NA_character_, list())
    })

    attributes <- recorded$traces[[1]]$attributes
    expect_identical(
      attributes[[contract$tag_attribute]],
      case$recorded,
      label = case$name
    )
    expect_identical(
      attributes[[contract$candidates_attribute]],
      "[]",
      label = case$name
    )
  }
})

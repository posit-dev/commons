test_that("new_trajectory_tracing validates its inputs", {
  expect_snapshot(new_trajectory_tracing(TRUE, share_with = 1), error = TRUE)
})

test_that("log = FALSE disables tracing", {
  expect_false(new_trajectory_tracing(FALSE))
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

test_that("log = TRUE warns when tracing stays disabled locally", {
  skip_if_not_installed("otel")
  withr::local_envvar(
    POSIT_PRODUCT = NA,
    CONNECT_CONTENT_GUID = NA,
    COMMONS_TRACES_DIR = "/tmp/commons-traces"
  )
  local_mocked_bindings(
    enable_content_capture = function() NULL,
    enable_local_tracing = function() invisible(FALSE)
  )

  expect_snapshot(.res <- new_trajectory_tracing(TRUE))
  expect_false(.res)
})

test_that("log = TRUE points at Content Observability on Connect", {
  skip_if_not_installed("otel")
  withr::local_envvar(CONNECT_CONTENT_GUID = "guid")
  clear_observability_attempted()
  state <- new.env()
  state$local_enabled <- FALSE
  local_mocked_bindings(
    enable_content_capture = function() NULL,
    enable_local_tracing = function() state$local_enabled <- TRUE,
    connect_client = function(...) rlang::abort("no api key")
  )

  expect_snapshot(.res <- new_trajectory_tracing(TRUE))
  expect_false(.res)
  expect_false(state$local_enabled)
})

test_that("tracing disabled on Connect flips the observability setting on", {
  skip_if_not_installed("otel")
  withr::local_envvar(CONNECT_CONTENT_GUID = "guid")
  clear_observability_attempted()
  state <- new.env()
  state$patched <- 0
  local_mocked_bindings(
    enable_content_capture = function() NULL,
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
  withr::local_envvar(CONNECT_CONTENT_GUID = "guid")
  clear_observability_attempted()
  state <- new.env()
  state$patched <- 0
  local_mocked_bindings(
    enable_content_capture = function() NULL,
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

test_that("enable_local_tracing configures the file exporter when unset", {
  skip_if_not_installed("otelsdk")
  dir <- withr::local_tempdir()
  withr::local_envvar(
    OTEL_TRACES_EXPORTER = NA,
    OTEL_EXPORTER_OTLP_TRACES_FILE = NA,
    COMMONS_TRACES_DIR = dir
  )
  local_mocked_bindings(
    reset_otel_tracer_provider = function() NULL,
    refresh_ellmer_otel_cache = function() NULL
  )

  enable_local_tracing()

  expect_equal(Sys.getenv("OTEL_TRACES_EXPORTER"), "otlp/file")
  expect_equal(
    Sys.getenv("OTEL_EXPORTER_OTLP_TRACES_FILE"),
    file.path(dir, "trace-%N.jsonl")
  )
})

test_that("enable_local_tracing respects an explicit exporter", {
  withr::local_envvar(OTEL_TRACES_EXPORTER = "none")
  reset <- FALSE
  local_mocked_bindings(
    reset_otel_tracer_provider = function() reset <<- TRUE
  )

  expect_false(enable_local_tracing())
  expect_false(reset)
  expect_equal(Sys.getenv("OTEL_TRACES_EXPORTER"), "none")
})

test_that("traces directory can come from COMMONS_TRACES_DIR", {
  withr::local_envvar(COMMONS_TRACES_DIR = NA)
  expect_equal(commons_traces_dir(), file.path(tempdir(), "commons-traces"))

  withr::local_envvar(COMMONS_TRACES_DIR = "/some/dir")
  expect_equal(commons_traces_dir(), "/some/dir")
})

test_that("conversation ids are unique and span-attribute safe", {
  ids <- replicate(20, new_conversation_id())
  expect_equal(anyDuplicated(ids), 0)
  expect_match(ids, "^[0-9]{8}t[0-9.]+-[a-z0-9]{10}$")
})

test_that("local_conversation_turn_span is a no-op without tracing", {
  skip_if_not_installed("otel")
  expect_null(local_conversation_turn_span("conv-1"))
})

test_that("share_trajectory_access warns off Connect", {
  withr::local_envvar(POSIT_PRODUCT = NA, CONNECT_CONTENT_GUID = NA)
  expect_snapshot(share_trajectory_access("jdoe"))
})

test_that("share_trajectory_access grants only missing collaborators", {
  withr::local_envvar(CONNECT_CONTENT_GUID = "content-guid")
  clear_granted_access()
  state <- new.env()
  state$added <- character()
  local_mocked_bindings(
    connect_client = function(...) list(server = "s", api_key = "k"),
    connect_permission_principals = function(client, guid) "guid-jdoe",
    connect_user_guid = function(client, username, ...) paste0("guid-", username),
    connect_add_collaborator = function(client, guid, principal_guid) {
      state$added <- c(state$added, principal_guid)
      invisible(NULL)
    }
  )

  share_trajectory_access(c("jdoe", "asmith"))

  expect_equal(state$added, "guid-asmith")
})

test_that("share_trajectory_access skips usernames already handled", {
  withr::local_envvar(CONNECT_CONTENT_GUID = "content-guid")
  clear_granted_access()
  state <- new.env()
  state$lookups <- 0
  local_mocked_bindings(
    connect_client = function(...) list(server = "s", api_key = "k"),
    connect_permission_principals = function(client, guid) character(),
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

test_that("an explicit content-capture setting is respected", {
  withr::local_envvar(OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "false")
  expect_snapshot(.res <- enable_content_capture())
  expect_false(.res)
  expect_equal(
    Sys.getenv("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"),
    "false"
  )

  withr::local_envvar(OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true")
  expect_no_warning(.res <- enable_content_capture())
  expect_false(.res)
})

test_that("content capture is enabled when unset", {
  withr::local_envvar(OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = NA)
  local_mocked_bindings(refresh_ellmer_otel_cache = function() NULL)

  expect_true(enable_content_capture())
  expect_equal(
    Sys.getenv("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"),
    "true"
  )
})

test_that("share_with grants wait for tracing to be live", {
  skip_if_not_installed("otel")
  withr::local_envvar(CONNECT_CONTENT_GUID = "guid")
  state <- new.env()
  state$shared <- FALSE
  local_mocked_bindings(
    enable_content_capture = function() NULL,
    enable_content_observability = function() NULL,
    share_trajectory_access = function(share_with) state$shared <- TRUE
  )

  suppressWarnings(.res <- new_trajectory_tracing(TRUE, share_with = "jdoe"))

  expect_false(.res)
  expect_false(state$shared)
})

# The tracing hacks reach into ellmer and otel internals and are written to
# degrade silently if those internals change; fail loudly here instead so an
# upgrade can't quietly stop trajectory capture.
test_that("the internals the tracing hacks rely on still exist", {
  skip_if_not_installed("otel")

  expect_true(is.function(asNamespace("ellmer")[["otel_cache_tracer"]]))

  the <- asNamespace("otel")[["the"]]
  expect_true(is.environment(the))
  expect_true(exists("tracer_provider", envir = the, inherits = FALSE))
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

test_that("conversation turn spans record the conversation id", {
  skip_if_not_installed("otelsdk")

  recorded <- otelsdk::with_otel_record({
    turn <- function() {
      local_conversation_turn_span("conv-1")
      invisible(NULL)
    }
    turn()
  })

  spans <- recorded$traces
  expect_length(spans, 1)
  expect_equal(spans[[1]]$name, "commons_conversation_turn")
  expect_equal(spans[[1]]$attributes[["gen_ai.conversation.id"]], "conv-1")
})

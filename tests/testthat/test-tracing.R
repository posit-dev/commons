test_that("new_trajectory_tracing validates its inputs", {
  expect_snapshot(new_trajectory_tracing("yes"), error = TRUE)
  expect_snapshot(new_trajectory_tracing(NA), error = TRUE)
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
  local_enabled <- FALSE
  local_mocked_bindings(
    enable_content_capture = function() NULL,
    enable_local_tracing = function() local_enabled <<- TRUE
  )

  expect_snapshot(.res <- new_trajectory_tracing(TRUE))
  expect_false(.res)
  expect_false(local_enabled)
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
  added <- character()
  local_mocked_bindings(
    connect_client = function(...) list(server = "s", api_key = "k"),
    connect_permission_principals = function(client, guid) "guid-jdoe",
    connect_user_guid = function(client, username, ...) paste0("guid-", username),
    connect_add_collaborator = function(client, guid, principal_guid) {
      added <<- c(added, principal_guid)
      invisible(NULL)
    }
  )

  share_trajectory_access(c("jdoe", "asmith"))

  expect_equal(added, "guid-asmith")
})

test_that("share_trajectory_access warns rather than errors on failure", {
  withr::local_envvar(CONNECT_CONTENT_GUID = "content-guid")
  local_mocked_bindings(
    connect_client = function(...) rlang::abort("no api key")
  )

  expect_snapshot(share_trajectory_access("jdoe"))
})

# Isolate the persistent context store cache per test session.
options(commons.context_cache = tempfile("commons-context-cache-"))
withr::defer(
  unlink(getOption("commons.context_cache"), recursive = TRUE),
  testthat::teardown_env()
)

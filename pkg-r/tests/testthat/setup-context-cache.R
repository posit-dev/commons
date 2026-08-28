# Isolate the persistent context store cache per test session so stores
# built by one test session don't mask build spans (or leak) in another.
options(commons.context_cache = tempfile("commons-context-cache-"))
withr::defer(
  unlink(getOption("commons.context_cache"), recursive = TRUE),
  testthat::teardown_env()
)

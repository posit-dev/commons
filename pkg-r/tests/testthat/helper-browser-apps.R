browser_test_app <- function(name) {
  normalizePath(test_path("apps", name), mustWork = TRUE)
}

skip_if_browser_tests_disabled <- function() {
  skip_if(
    identical(Sys.getenv("COMMONS_SKIP_BROWSER_TESTS"), "true"),
    "Browser tests are disabled for this test job."
  )
}

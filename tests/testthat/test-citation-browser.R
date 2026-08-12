test_that("normal package checks can disable browser tests explicitly", {
  withr::local_envvar(COMMONS_SKIP_BROWSER_TESTS = "true")
  expect_condition(
    skip_if_browser_tests_disabled(),
    class = "skip",
    regexp = "Browser tests are disabled"
  )
})

test_that("Shiny Chat renders one server-verified streamed citation", {
  skip_on_cran()
  skip_if_not_installed("shinytest2")
  skip_if_not_installed("chromote")
  skip_if_browser_tests_disabled()

  app <- shinytest2::AppDriver$new(
    browser_test_app("citation-stream"),
    name = "citation-stream",
    timeout = 30 * 1000,
    load_timeout = 30 * 1000
  )
  withr::defer(app$stop())

  app$wait_for_js(
    "document.body.innerText.includes('After citations.');",
    timeout = 30 * 1000
  )
  app$wait_for_js(
    "document.querySelectorAll('.shiny-aside-group').length === 1;",
    timeout = 30 * 1000
  )
  app$wait_for_js(
    paste0(
      "document.querySelector(",
      "'.shiny-aside-pill img[src$=\"/citation-prose.svg\"]'",
      ") !== null;"
    ),
    timeout = 30 * 1000
  )

  expect_identical(
    app$get_js(
      "document.querySelector('.shiny-aside-pill__label')?.innerText;"
    ),
    "documentation"
  )

  # The fixture streams five chunks and shinychat re-renders the message on
  # each one, so a pill that exists mid-stream is replaced before its popover
  # can open. "After citations." is the final chunk: waiting for it lands the
  # click on settled DOM.
  app$wait_for_js(
    paste0(
      "document.querySelector('.shiny-chat-message')",
      "?.innerText.includes('After citations.') === true;"
    ),
    timeout = 30 * 1000
  )

  app$get_js(
    "document.querySelector('.shiny-aside-pill')?.click();"
  )
  app$wait_for_js(
    "document.querySelector('.shiny-aside-popover') !== null;",
    timeout = 30 * 1000
  )
  popover_text <- app$get_js(
    "document.querySelector('.shiny-aside-popover')?.innerText;"
  )
  expect_match(popover_text, "Supports the reported weighting.", fixed = TRUE)
  expect_match(
    popover_text,
    "Canopy cover is always acre-weighted for reporting.",
    fixed = TRUE
  )

  answer <- app$get_js(
    "document.querySelector('.shiny-chat-message')?.innerText;"
  )
  answer_html <- app$get_js(
    "document.querySelector('.shiny-chat-message')?.innerHTML;"
  )
  expect_match(answer, "Before citations.", fixed = TRUE)
  expect_match(answer, "After citations.", fixed = TRUE)
  expect_no_match(answer_html, "commons-citation", fixed = TRUE)

  # The fixture streams an unsupported citation and a model-authored
  # <shiny-aside> alongside the verified one. Which elements the scanner drops
  # is covered exhaustively in test-citation-scan.R; asserting the group count
  # here is what proves the scanner runs in the live streaming path at all.
  expect_identical(
    app$get_js("document.querySelectorAll('.shiny-aside-group').length === 1;"),
    TRUE
  )
})

test_that("Shiny Chat distinguishes verified, cited, and untrusted asides", {
  skip_on_cran()
  skip_if_not_installed("shinytest2")
  skip_if_not_installed("chromote")
  skip_if_browser_tests_disabled()

  app <- shinytest2::AppDriver$new(
    browser_test_app("aside-states"),
    name = "aside-states",
    timeout = 30 * 1000,
    load_timeout = 30 * 1000
  )
  withr::defer(app$stop())

  app$wait_for_js(
    "document.querySelectorAll('.shiny-aside-pill img').length === 3;",
    timeout = 30 * 1000
  )

  labels <- app$get_js(
    paste0(
      "Array.from(document.querySelectorAll('.shiny-aside-pill__label'))",
      ".map((node) => node.innerText).join('|');"
    )
  )
  expect_identical(labels, "Verified answer|documentation|Untrusted")

  expect_identical(
    app$get_js(
      paste0(
        "document.querySelector(",
        "'.shiny-aside-pill:has(img[src$=\"/citation-prose.svg\"])'",
        ").closest('p')?.innerText.includes('Supported claim.');"
      )
    ),
    TRUE
  )
})

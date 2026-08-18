test_that("normal package checks can disable browser tests explicitly", {
  withr::local_envvar(COMMONS_SKIP_BROWSER_TESTS = "true")
  expect_condition(
    skip_if_browser_tests_disabled(),
    class = "skip",
    regexp = "Browser tests are disabled"
  )
})

test_that("Shiny Chat numbers adjacent server-verified citations", {
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
    "document.querySelectorAll('.shiny-aside-group').length === 2;",
    timeout = 30 * 1000
  )
  app$wait_for_js(
    "document.querySelectorAll('.shiny-aside-pill--count').length === 2;",
    timeout = 30 * 1000
  )

  expect_identical(
    app$get_js(
      paste0(
        "Array.from(document.querySelectorAll('.shiny-aside-pill--count'))",
        ".map((node) => node.textContent).join('|');"
      )
    ),
    "1|2"
  )
  expect_identical(
    app$get_js(
      paste0(
        "Array.from(document.querySelectorAll('.shiny-aside-pill--count'))",
        ".map((node) => node.getAttribute('aria-label')).join('|');"
      )
    ),
    "Aside 1|Aside 2"
  )

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
  expect_match(popover_text, "documentation", fixed = TRUE)
  expect_match(
    popover_text,
    "Canopy cover is always acre-weighted for reporting.",
    fixed = TRUE
  )
  expect_identical(
    app$get_js(
      paste0(
        "document.querySelector(",
        "'.commons-source-heading img[src$=\"/citation-prose.svg\"]'",
        ") !== null;"
      )
    ),
    TRUE
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

  expect_identical(
    app$get_js("document.querySelectorAll('.shiny-aside-group').length === 2;"),
    TRUE
  )
  expect_identical(
    app$get_js(
      paste0(
        "Array.from(document.querySelectorAll('.shiny-aside-group'))",
        ".every((node) => ",
        "node.closest('p')?.innerText.includes('Before citations.'));"
      )
    ),
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
    "document.querySelectorAll('.shiny-aside-pill img').length === 2;",
    timeout = 30 * 1000
  )

  labels <- app$get_js(
    paste0(
      "Array.from(document.querySelectorAll('.shiny-aside-pill__label'))",
      ".map((node) => node.textContent).join('|');"
    )
  )
  expect_identical(labels, "Verified answer|Untrusted")
  expect_identical(
    app$get_js(
      "getComputedStyle(document.querySelector('.shiny-aside-pill')).fontWeight;"
    ),
    "400"
  )
  expect_identical(
    app$get_js(
      "document.querySelector('.shiny-aside-pill--count')?.textContent;"
    ),
    "1"
  )
  expect_identical(
    app$get_js(
      paste0(
        "getComputedStyle(document.querySelector(",
        "'.shiny-aside-pill--count'",
        ").closest('.shiny-aside-group')).marginInlineStart;"
      )
    ),
    "0px"
  )
  expect_identical(
    app$get_js(
      paste0(
        "getComputedStyle(document.querySelector(",
        "'.shiny-aside-pill--count'",
        ")).boxShadow;"
      )
    ),
    "none"
  )

  expect_identical(
    app$get_js(
      paste0(
        "document.querySelector(",
        "'.shiny-aside-pill--count'",
        ").closest('p')?.innerText.includes('Supported claim.');"
      )
    ),
    TRUE
  )
})

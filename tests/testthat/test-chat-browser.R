test_that("Commons shows feedback while a chat response is pending", {
  skip_on_cran()
  skip_if_not_installed("shinytest2")
  skip_if_not_installed("chromote")
  skip_if_browser_tests_disabled()

  app <- shinytest2::AppDriver$new(
    browser_test_app("chat-pending"),
    name = "chat-pending",
    timeout = 30 * 1000,
    load_timeout = 30 * 1000
  )
  withr::defer(app$stop())

  app$wait_for_js(
    "document.querySelector('.suggestion');",
    timeout = 30 * 1000
  )
  app$get_js(
    "document.querySelector('.suggestion').click();"
  )
  app$wait_for_js(
    paste0(
      "document.querySelector(",
      "'.shiny-chat-message > .shiny-chat-message-content:empty'",
      ");"
    ),
    timeout = 30 * 1000
  )
  app$wait_for_js(
    paste0(
      "getComputedStyle(document.querySelector(",
      "'.shiny-chat-message > .shiny-chat-message-content:empty'",
      "), '::before').opacity === '1';"
    ),
    timeout = 30 * 1000
  )

  expect_identical(
    app$get_js(
      paste0(
        "getComputedStyle(document.querySelector(",
        "'.shiny-chat-message > .shiny-chat-message-content:empty'",
        "), '::before').content;"
      )
    ),
    '"Working…"'
  )
  expect_identical(
    app$get_js(
      paste0(
        "document.querySelector('",
        ".shiny-chat-btn-send[aria-label=\"Loading\"], ",
        ".shiny-chat-btn-cancel[aria-label=\"Stop generating\"]",
        "') !== null;"
      )
    ),
    TRUE
  )

  app$wait_for_js(
    "document.body.innerText.includes('The response is ready.');",
    timeout = 30 * 1000
  )
  expect_identical(
    app$get_js(
      paste0(
        "document.querySelector(",
        "'.shiny-chat-message > .shiny-chat-message-content:empty'",
        ") === null;"
      )
    ),
    TRUE
  )
})

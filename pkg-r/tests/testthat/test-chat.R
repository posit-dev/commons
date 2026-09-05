test_that("commons_app builds a single-user app on page_chat", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("shinychat")

  app <- commons_app(test_agent())

  expect_s3_class(app, "shiny.appobj")
  expect_identical(app$appOptions$bookmarkStore, "url")

  app_env <- environment(app$serverFuncSource)
  ui <- app_env$ui(NULL)
  chat <- htmltools::tagQuery(ui)$find("shiny-chat-container")$selectedTags()
  deps <- htmltools::findDependencies(ui)

  expect_length(chat, 1)
  # Left unset so chat_server() decides (it enables both automatically).
  expect_null(chat[[1]]$attribs[["allow-attachments"]])
  expect_null(chat[[1]]$attribs[["enable-cancel"]])
  expect_true("commons-chat" %in% vapply(deps, `[[`, character(1), "name"))

  shiny::testServer(app_env$server, {
    session$flushReact()
  })
})

test_that("commons_server registers no custom-message observers", {
  body_text <- paste(deparse(body(commons_server)), collapse = "\n")
  expect_false(grepl("sendCustomMessage", body_text, fixed = TRUE))
})

test_that("commons_server runs under shiny::testServer without error", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("shinychat")

  shiny::testServer(
    function(input, output, session) {
      commons_server("chat", client = test_agent())
    },
    {
      session$flushReact()
    }
  )
  succeed()
})

test_that("commons_theme() bundles the commons chat assets", {
  theme <- commons_theme()

  expect_s3_class(theme, "bs_theme")
  deps <- bslib::bs_theme_dependencies(theme)
  names <- vapply(deps, `[[`, character(1), "name")
  expect_true("commons-chat" %in% names)

  commons_dep <- deps[[which(names == "commons-chat")]]
  expect_identical(commons_dep$stylesheet, "commons-chat.css")
  expect_identical(commons_dep$script, "commons-chat.js")
})

test_that("icon URLs resolve inside the commons-chat dependency", {
  url <- commons_icon_url("trusted-icon.svg")
  expect_match(url, "^commons-chat-[^/]+/figs/trusted-icon\\.svg$")

  # The dependency ships the file the URL points to
  dep <- commons_chat_dependency()
  expect_true(file.exists(file.path(dep$src$file, "figs", "trusted-icon.svg")))
})

test_that("commons_app requires a commons agent", {
  expect_snapshot(
    commons_app(test_client()),
    error = TRUE
  )
})

test_that("commons_server requires a commons agent", {
  expect_snapshot(
    commons_server("chat", client = test_client()),
    error = TRUE
  )
})

test_that("commons_app() prewarms the agent on idle", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("shinychat")

  app <- commons_app(test_agent())
  app_env <- environment(app$serverFuncSource)
  prewarmed <- FALSE
  testthat::local_mocked_bindings(
    prewarm_on_idle = function(client) prewarmed <<- TRUE,
    .package = "commons"
  )
  shiny::testServer(app_env$server, {
    session$flushReact()
  })
  expect_true(prewarmed)
})

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

test_that("commons_server queues a restore reminder when history is restored", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("shinychat")

  shiny::testServer(
    function(input, output, session) {
      agent <- test_agent()
      chat <- commons_server("chat", client = agent)
    },
    {
      controller <- shinychat:::get_session_chat_bookmark_info(
        session,
        "chat.history-controller"
      )
      controller$restore_app_state(list())
      expect_true(agent$.__enclos_env__$private$restore_reminder_pending)

      chat$clear()
      expect_false(agent$.__enclos_env__$private$restore_reminder_pending)

      controller$restore_app_state(list())
      controller$new_chat()
      expect_false(agent$.__enclos_env__$private$restore_reminder_pending)
    }
  )
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

test_that("commons_prewarm() downgrades prewarm failures to warnings", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# Revenue", "", "Revenue means booked revenue."), path)
  agent <- test_agent(context_layer = context_layer(files = path))

  local_mocked_bindings(
    context_store = function(...) stop("index build exploded"),
    .package = "commons"
  )
  expect_warning(
    commons_prewarm(agent, cache_dir = withr::local_tempdir()),
    "index build exploded"
  )
})

test_that("commons_prewarm() warns on failures with braces in the message", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# Revenue", "", "Revenue means booked revenue."), path)
  agent <- test_agent(context_layer = context_layer(files = path))

  # DuckDB errors embed JSON; cli must not interpolate the raw message
  local_mocked_bindings(
    context_store = function(...) stop('bad store: {"code": 1}'),
    .package = "commons"
  )
  expect_warning(
    commons_prewarm(agent, cache_dir = withr::local_tempdir()),
    "bad store",
    fixed = TRUE
  )
})

test_that("commons_prewarm(cache_dir =) builds the store in that directory", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# Revenue", "", "Revenue means booked revenue."), path)
  agent <- test_agent(context_layer = context_layer(files = path))

  cache_dir <- withr::local_tempdir()
  expect_message(
    commons_prewarm(agent, cache_dir = cache_dir),
    "Warmed the context index cache"
  )
  expect_length(list.files(file.path(cache_dir, "context")), 1)
})

test_that("commons_prewarm() warns when there is nothing to cache", {
  expect_warning(
    commons_prewarm(test_agent(), cache_dir = withr::local_tempdir()),
    "No context index was cached"
  )
})

test_that("commons_prewarm() validates cache_dir", {
  expect_error(
    commons_prewarm(test_agent(), cache_dir = TRUE),
    "must be a path"
  )
  expect_error(
    commons_prewarm(test_agent()),
    "cache_dir.* is required"
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

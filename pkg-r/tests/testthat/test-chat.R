test_that("commons_app builds a single-user app on page_chat", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("shinychat")

  app <- commons_app(test_agent())

  expect_s3_class(app, "shiny.appobj")
  expect_identical(app$appOptions$bookmarkStore, "url")

  app_env <- environment(app$serverFuncSource)
  ui <- app_env$ui(NULL)
  deps <- htmltools::findDependencies(ui)

  expect_true("commons-chat" %in% vapply(deps, `[[`, character(1), "name"))

  shiny::testServer(app_env$server, {
    session$flushReact()
  })

  # shiny-chat-container is private to shinychat; skipped on CRAN so
  # shinychat's reverse dependency checks don't fail.
  skip_on_cran()
  chat <- htmltools::tagQuery(ui)$find("shiny-chat-container")$selectedTags()
  expect_length(chat, 1)
  # Left unset so chat_server() decides (it enables both automatically).
  expect_null(chat[[1]]$attribs[["allow-attachments"]])
  expect_null(chat[[1]]$attribs[["enable-cancel"]])
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
  # Drives shinychat internals; skipped on CRAN so shinychat's reverse
  # dependency checks don't fail.
  skip_on_cran()
  skip_if_not_installed("shiny")
  skip_if_not_installed("shinychat")

  shiny::testServer(
    function(input, output, session) {
      agent <- test_agent()
      chat <- commons_server("chat", client = agent)
    },
    {
      # shinychat has no public hook to fire a restore under testServer, so
      # drive the history controller it stashes on the session.
      controller <- shinychat:::get_session_chat_bookmark_info(
        session,
        "chat.history-controller"
      )
      controller$restore_app_state(list())
      expect_true(agent$.__enclos_env__$private$restore_reminder_pending)

      chat$new_chat()
      expect_false(agent$.__enclos_env__$private$restore_reminder_pending)
    }
  )
})

test_that("documents are saved with the chat and editable once restored", {
  # Drives shinychat internals; skipped on CRAN so shinychat's reverse
  # dependency checks don't fail.
  skip_on_cran()
  skip_if_not_installed("shiny")
  skip_if_not_installed("shinychat")

  history_controller <- function(session) {
    shinychat:::get_session_chat_bookmark_info(
      session,
      "chat.history-controller"
    )
  }

  values <- NULL
  shiny::testServer(
    function(input, output, session) {
      agent <- test_agent()
      commons_server("chat", client = agent)
    },
    {
      store <- agent$artifact_store()
      wait_for_promise(artifact_commit(store, "doc", "Doc", "First.\n")$rendered)
      wait_for_promise(artifact_edit(store, "doc", "First.", "Second."))
      # shinychat has no public hook to save under testServer.
      values <<- history_controller(session)$.__enclos_env__$private$capture_app_state()
    }
  )
  expect_length(values$commons_artifacts$doc$sources, 2)
  # History persists values as JSON.
  values <- jsonlite::fromJSON(jsonlite::toJSON(values, auto_unbox = TRUE))

  shiny::testServer(
    function(input, output, session) {
      agent <- test_agent()
      commons_server("chat", client = agent)
    },
    {
      history_controller(session)$restore_app_state(values)
      store <- agent$artifact_store()
      result <- wait_for_promise(artifact_edit(store, "doc", "Second.", "Third."))
      expect_identical(result@value, "Saved version 3 of `doc`.")
      expect_match(
        paste(artifact_get(store, "doc")$html, collapse = ""),
        "Third.",
        fixed = TRUE
      )
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
  expect_identical(
    commons_dep$stylesheet,
    c("commons-chat.css", "commons-artifact.css")
  )
  expect_identical(
    commons_dep$script,
    c("commons-chat.js", "commons-artifact.js")
  )
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

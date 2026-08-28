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

test_that("persist_conversation_id round-trips the id through history hooks", {
  agent <- test_agent()
  hooks <- new.env(parent = emptyenv())
  fake_chat <- list(
    history = list(
      on_save = function(fn) hooks$on_save <- fn,
      on_restore = function(fn) hooks$on_restore <- fn
    )
  )

  persist_conversation_id(fake_chat, agent)

  values <- hooks$on_save(list(app_state = 1))
  expect_identical(
    values$commons_conversation_id,
    agent$get_conversation_id()
  )
  expect_identical(values$app_state, 1)

  hooks$on_restore(list(commons_conversation_id = "restored-id"))
  expect_identical(agent$get_conversation_id(), "restored-id")
  expect_true(agent$.__enclos_env__$private$restore_reminder_pending)

  hooks$on_restore(list())
  expect_identical(agent$get_conversation_id(), "restored-id")
  expect_true(agent$.__enclos_env__$private$restore_reminder_pending)
})

test_that("commons_server wires conversation-id persistence into shinychat", {
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
      controller$restore_app_state(
        list(commons_conversation_id = "restored-id")
      )
      expect_identical(agent$get_conversation_id(), "restored-id")
      expect_true(agent$.__enclos_env__$private$restore_reminder_pending)

      chat$clear()
      expect_false(agent$.__enclos_env__$private$restore_reminder_pending)

      controller$restore_app_state(
        list(commons_conversation_id = "restored-id")
      )
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

test_that("commons_theme() configures shinychat geometry", {
  variables <- bslib::bs_get_variables(
    commons_theme(),
    c(
      "shiny-chat-suggestion-card-border-radius",
      "shiny-chat-user-message-border-radius",
      "shiny-chat-user-message-padding"
    )
  )

  expect_identical(
    unname(variables),
    c("0.75rem", "0.75rem", "0.5rem 1.5rem")
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

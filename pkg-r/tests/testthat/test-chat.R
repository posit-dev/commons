test_that("commons_app builds a single-user app from commons chat wrappers", {
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
  expect_true(is.na(chat[[1]]$attribs[["allow-attachments"]]))
  expect_true(is.na(chat[[1]]$attribs[["enable-cancel"]]))
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

test_that("commons_theme() registers the packaged icon resource path", {
  prefix <- "commons-icons"
  paths <- shiny::resourcePaths()
  previous <- if (prefix %in% names(paths)) unname(paths[[prefix]])
  if (!is.null(previous)) {
    shiny::removeResourcePath(prefix)
  }
  withr::defer({
    if (prefix %in% names(shiny::resourcePaths())) {
      shiny::removeResourcePath(prefix)
    }
    if (!is.null(previous)) {
      shiny::addResourcePath(prefix, previous)
    }
  })

  commons_theme()

  paths <- shiny::resourcePaths()
  expect_in(prefix, names(paths))
  expect_identical(
    unname(paths[prefix]),
    normalizePath(system.file("figs", package = "commons"))
  )
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

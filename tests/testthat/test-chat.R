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
      commons_server("chat", client = agent)
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
    }
  )
})

test_that("chat UI preserves shinychat's top-level fill container", {
  ui <- commons_ui("chat", height = "100%")
  classes <- unlist(ui$attribs[names(ui$attribs) == "class"], use.names = FALSE)
  deps <- htmltools::findDependencies(ui)

  expect_equal(ui$name, "shiny-chat-container")
  expect_identical(ui$attribs[["icon-assistant"]], "")
  # shinychat controls the width property's name (it moved from `width` to a
  # `--_chat-width` variable in 0.5.0); commons only cares that arguments in
  # `...` reach chat_ui()'s formals and the default width cap is intact.
  expect_match(ui$attribs$style, "min\\(680px, 100%\\)")
  expect_match(ui$attribs$style, "height:100%;")
  expect_true("html-fill-item" %in% classes)
  expect_true("html-fill-container" %in% classes)
  expect_true("commons-chat" %in% vapply(deps, `[[`, character(1), "name"))
})

test_that("chat UI registers the packaged icon resource path", {
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

  commons_ui("chat")

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

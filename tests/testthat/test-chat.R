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

test_that("conversation state round-trips through history hooks", {
  agent <- test_agent()
  hooks <- new.env(parent = emptyenv())
  messages <- new.env(parent = emptyenv())
  fake_chat <- list(
    history = list(
      on_save = function(fn) hooks$on_save <- fn,
      on_restore = function(fn) hooks$on_restore <- fn
    )
  )
  fake_session <- list(
    input = list(
      chat_resume_boundaries = c(2L, 4L, 7L),
      chat_messages = rep(list(list(role = "assistant")), 5)
    ),
    ns = function(id) paste0("module-", id),
    sendCustomMessage = function(type, message) {
      messages$type <- type
      messages$message <- message
    }
  )

  persist_conversation_state(fake_chat, agent, "chat", fake_session)

  values <- hooks$on_save(list(app_state = 1))
  expect_identical(
    values$commons_conversation_id,
    agent$get_conversation_id()
  )
  expect_identical(values$commons_resume_boundaries, c(2L, 4L))
  expect_identical(values$app_state, 1)

  hooks$on_restore(list(commons_conversation_id = "restored-id"))
  expect_identical(agent$get_conversation_id(), "restored-id")
  expect_true(agent$.__enclos_env__$private$restore_reminder_pending)
  expect_identical(messages$type, "commonsResumeConversation")
  expect_identical(
    messages$message,
    list(
      id = "module-chat",
      input_id = "module-chat_resume_boundaries",
      boundaries = integer()
    )
  )

  hooks$on_restore(list(commons_resume_boundaries = c(2, 4)))
  expect_identical(agent$get_conversation_id(), "restored-id")
  expect_true(agent$.__enclos_env__$private$restore_reminder_pending)
  expect_identical(messages$message$boundaries, c(2L, 4L))

  hooks$on_restore(list())
  expect_identical(messages$message$boundaries, integer())
})

test_that("resume boundary ordinals are valid message positions", {
  expect_identical(
    resume_boundary_ordinals(c(4, NA, 2, 4, 0, 7), message_count = 5),
    c(2L, 4L)
  )
  expect_identical(resume_boundary_ordinals(NULL), integer())
})

test_that("resume boundaries accumulate and survive UI replay", {
  skip_on_cran()
  skip_if_not_installed("shinytest2")
  skip_if_not_installed("chromote")
  skip_if_browser_tests_disabled()

  app <- shinytest2::AppDriver$new(
    browser_test_app("resume-boundaries"),
    name = "resume-boundaries",
    timeout = 30 * 1000,
    load_timeout = 30 * 1000
  )
  withr::defer(app$stop())

  boundary_positions <- paste0(
    "Array.from(document.querySelectorAll(",
    "'.shiny-chat-messages-content > div'))",
    ".map((node, index) => node.classList.contains(",
    "'commons-resume-boundary') ? index + 1 : null)",
    ".filter((index) => index !== null).join(',');"
  )
  app$wait_for_js(
    "document.querySelectorAll('.commons-resume-boundary').length === 3;",
    timeout = 30 * 1000
  )
  expect_identical(app$get_js(boundary_positions), "2,4,6")
  expect_match(
    app$get_js(
      paste0(
        "getComputedStyle(document.querySelector(",
        "'.commons-resume-boundary'), '::after').content;"
      )
    ),
    "Resuming previous conversation",
    fixed = TRUE
  )

  app$click("replay")
  app$wait_for_js(
    paste0(
      "document.querySelector('.shiny-chat-messages-content')",
      ".textContent.includes('Replayed Answer three');"
    ),
    timeout = 30 * 1000
  )
  app$wait_for_js(
    "document.querySelectorAll('.commons-resume-boundary').length === 3;",
    timeout = 30 * 1000
  )
  expect_identical(app$get_js(boundary_positions), "2,4,6")

  app$click("clear")
  app$wait_for_js(
    "document.querySelectorAll('.shiny-chat-messages-content > div').length === 0;",
    timeout = 30 * 1000
  )
  app$wait_for_js(
    "document.getElementById('chat').commonsResumeState.boundaries.length === 0;",
    timeout = 30 * 1000
  )
  app$click("append")
  app$wait_for_js(
    "document.querySelectorAll('.shiny-chat-messages-content > div').length === 1;",
    timeout = 30 * 1000
  )
  expect_identical(
    app$get_js("document.querySelectorAll('.commons-resume-boundary').length;"),
    0L
  )
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

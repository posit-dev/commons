test_that("commons_server registers no custom-message observers", {
  # The live chat's provenance and citations now arrive as server-authored
  # <shiny-aside> elements already inline in the stream (see R/provenance.R,
  # R/citation-scan.R) -- commons_server() has nothing left to push to the
  # client, unlike the retired pill protocol this guards against reviving.
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

test_that("commons_server requires a commons agent", {
  expect_snapshot(
    commons_server("chat", client = test_client()),
    error = TRUE
  )
})

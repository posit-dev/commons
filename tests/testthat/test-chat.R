test_that("answer pills describe trusted and uncited fallback answers", {
  trusted <- htmltools::renderTags(commons_answer_pill("A"))$html
  uncited <- htmltools::renderTags(commons_answer_pill("C"))$html

  expect_match(trusted, "Verified answer")
  expect_match(trusted, "governed calculation")
  expect_match(trusted, "data-commons-tooltip")
  expect_match(trusted, "commons-answer-pill-icon")
  expect_match(trusted, "commons-answer-pill-trusted")

  expect_match(uncited, "Potentially untrusted")
  expect_match(uncited, "AI can be wrong")
  expect_match(uncited, "not produced by a governed calculation")
  expect_match(uncited, "data-commons-tooltip")
  expect_match(uncited, "commons-answer-pill-icon")
  expect_match(uncited, "commons-answer-pill-caution")
})

test_that("cited fallback answers get footnotes rather than a pill", {
  expect_null(commons_answer_pill("B"))
  expect_equal(
    as.character(htmltools::renderTags(commons_answer_pill("B"))$html),
    ""
  )
})

test_that("citations_payload aligns entries with the answer's citations", {
  payload <- citations_payload(list(
    list(quote = "Revenue  excludes tax.", label = "context layer", verified = TRUE),
    list(quote = "Made up.", label = NA_character_, verified = FALSE)
  ))

  expect_length(payload, 2)
  expect_true(payload[[1]]$verified)
  expect_match(payload[[1]]$tooltip, "Revenue excludes tax")
  expect_match(payload[[1]]$tooltip, "context layer")
  expect_false(payload[[2]]$verified)
  expect_null(payload[[2]]$tooltip)
})

test_that("chat UI preserves shinychat's top-level fill container", {
  ui <- commons_mod_ui("chat")
  classes <- unlist(ui$attribs[names(ui$attribs) == "class"], use.names = FALSE)
  deps <- htmltools::findDependencies(ui)

  expect_equal(ui$name, "shiny-chat-container")
  # shinychat controls the width property's name (it moved from `width` to a
  # `--_chat-width` variable in 0.5.0); commons only cares that its height
  # rides through and the default width cap is intact.
  expect_match(ui$attribs$style, "min\\(680px, 100%\\)")
  expect_match(ui$attribs$style, "height:100%;")
  expect_true("html-fill-item" %in% classes)
  expect_true("html-fill-container" %in% classes)
  expect_true("commons-chat" %in% vapply(deps, `[[`, character(1), "name"))
})

test_that("commons_mod_server requires a commons agent", {
  expect_snapshot(
    commons_mod_server("chat", client = test_client()),
    error = TRUE
  )
})

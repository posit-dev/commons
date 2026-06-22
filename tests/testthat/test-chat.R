test_that("answer pills describe trusted and fallback answers", {
  trusted <- htmltools::renderTags(commons_answer_pill("A"))$html
  fallback <- htmltools::renderTags(
    commons_answer_pill("B", "review")
  )$html

  expect_match(trusted, "Verified answer")
  expect_match(trusted, "governed calculation")
  expect_match(trusted, "data-commons-tooltip")
  expect_match(trusted, "commons-answer-pill-icon")
  expect_match(trusted, "commons-answer-pill-trusted")

  expect_match(fallback, "AI can be wrong")
  expect_match(fallback, "not produced by a governed calculation")
  expect_match(fallback, "data-commons-tooltip")
  expect_match(fallback, "request review")
  expect_match(fallback, "commons-answer-pill-icon")
  expect_no_match(fallback, "request review\\s+\\.")
  expect_match(fallback, "commons-answer-pill-caution")
})

test_that("chat UI preserves shinychat's top-level fill container", {
  ui <- commons_mod_ui("chat")
  classes <- unlist(ui$attribs[names(ui$attribs) == "class"], use.names = FALSE)
  deps <- htmltools::findDependencies(ui)

  expect_equal(ui$name, "shiny-chat-container")
  expect_equal(ui$attribs$style, "width:min(680px, 100%);height:100%;")
  expect_true("html-fill-item" %in% classes)
  expect_true("html-fill-container" %in% classes)
  expect_true("commons-chat" %in% vapply(deps, `[[`, character(1), "name"))
})

test_that("review requests include the previous request and answer", {
  prompt <- review_request_prompt(
    "How many orders were there?",
    "There were 6 orders."
  )

  expect_match(prompt, "Briefly note assumptions")
  expect_match(prompt, "one or two other possible different answers")
  expect_no_match(prompt, "How many orders were there?", fixed = TRUE)
  expect_no_match(prompt, "There were 6 orders.", fixed = TRUE)
})

test_that("commons_mod_server requires a commons agent", {
  expect_snapshot(
    commons_mod_server("chat", client = test_client()),
    error = TRUE
  )
})

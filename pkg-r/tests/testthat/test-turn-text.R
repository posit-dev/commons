test_that("new assistant texts carry their display beside the model's text", {
  raw <- "Intro.\n<artifact id=\"doc\" title=\"Doc\">\n---\ntitle: Doc\n---\nBody\n</artifact>\nAfter."
  old <- ellmer::AssistantTurn(list(ellmer::ContentText("Earlier.")))
  new <- ellmer::AssistantTurn(list(
    ellmer::ContentText(raw),
    ellmer::ContentThinking("thinking"),
    ellmer::ContentText("Last.")
  ))
  turns <- list(
    ellmer::UserTurn(list(ellmer::ContentText("q1"))),
    old,
    ellmer::UserTurn(list(ellmer::ContentText("q2"))),
    new
  )

  out <- with_display_text(turns, 3, list(), links = "<chip>", aside = "<aside>")

  expect_identical(out[1:2], turns[1:2])
  contents <- out[[4]]@contents
  expect_identical(contents[[1]]@text, raw)
  expect_identical(contents[[1]]@display, "Intro.\n<chip>\nAfter.")
  expect_identical(contents[[2]], new@contents[[2]])
  expect_identical(contents[[3]]@display, "Last.<aside>")
  expect_identical(
    shinychat::contents_shinychat(contents[[1]]),
    "Intro.\n<chip>\nAfter."
  )
})

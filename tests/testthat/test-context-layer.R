test_that("context_layer indexes files and finds relevant chunks", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(
    c(
      "# Revenue",
      "Revenue excludes tax unless stated otherwise.",
      "",
      "# Discounts",
      "Discounts are applied before tax."
    ),
    path
  )

  layer <- context_layer(files = path)
  hits <- context_search(layer, "what does revenue mean")

  expect_gte(length(hits), 1)
  expect_match(hits[[1]], "tax")
})

test_that("context_search returns empty when nothing matches or store is empty", {
  expect_length(context_search(context_layer(), "anything"), 0)

  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# A", "apples"), path)
  expect_length(context_search(context_layer(files = path), "zzzzz"), 0)
})

test_that("prompt facts are carried on the layer", {
  layer <- context_layer(always = "Revenue excludes tax.")
  expect_equal(layer$always, "Revenue excludes tax.")
})

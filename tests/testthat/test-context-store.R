test_that("context_store indexes files and finds relevant chunks", {
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

  store <- context_store(files = path)
  hits <- context_search(store, "what does revenue mean")

  expect_gte(length(hits), 1)
  expect_match(hits[[1]], "tax")
})

test_that("context_search returns empty when nothing matches or store is empty", {
  expect_length(context_search(context_store(), "anything"), 0)

  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# A", "apples"), path)
  expect_length(context_search(context_store(files = path), "zzzzz"), 0)
})

test_that("prompt facts are carried on the store", {
  store <- context_store(always = "Revenue excludes tax.")
  expect_equal(store$always, "Revenue excludes tax.")
})

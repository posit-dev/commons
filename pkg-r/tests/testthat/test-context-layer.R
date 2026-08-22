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

test_that("context_layer strips YAML frontmatter before indexing", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(
    c(
      "---",
      "provenance: https://github.com/org/app/blob/abc1234/R/server.R#L1-L9",
      "---",
      "# Revenue",
      "Revenue excludes tax unless stated otherwise."
    ),
    path
  )

  layer <- context_layer(files = path)

  expect_match(context_search(layer, "revenue")[[1]], "tax")
  expect_length(context_search(layer, "abc1234"), 0)
})

test_that("context_layer leaves a body thematic break intact", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(
    c(
      "# Intro",
      "Revenue excludes tax.",
      "",
      "---",
      "",
      "# Details",
      "Discounts are applied before tax."
    ),
    path
  )

  layer <- context_layer(files = path)

  expect_match(context_search(layer, "discounts")[[1]], "before tax")
})

test_that("strip_frontmatter leaves a file without frontmatter unchanged", {
  md <- "# Revenue\nRevenue excludes tax."
  expect_equal(strip_frontmatter(md), md)
})

test_that("context_layer skips a frontmatter-only file", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("---", "provenance: some-source", "---"), path)

  layer <- context_layer(files = path)
  expect_length(context_search(layer, "provenance"), 0)
})

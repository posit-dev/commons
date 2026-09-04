test_that("strip_frontmatter matches the shared cases", {
  cases <- shared_fixture("context_layer")$strip_frontmatter$cases
  # An empty list would make the loop below vacuously succeed.
  expect_gt(length(cases), 0)

  for (case in cases) {
    expect_identical(
      strip_frontmatter(case$input),
      case$expected,
      info = case$name
    )
  }
})

test_that("dictionary_context_chunks matches the shared cases", {
  cases <- shared_fixture("context_layer")$dictionary_context_chunks$cases
  # An empty list would make the loop below vacuously succeed.
  expect_gt(length(cases), 0)

  for (case in cases) {
    dictionary <- if (is.null(case$dictionary)) {
      NULL
    } else {
      new_data_dictionary(case$dictionary)
    }
    expect_identical(
      dictionary_context_chunks(dictionary),
      as.character(unlist(case$expected)),
      info = case$name
    )
  }
})

test_that("augment_context_layer matches the shared cases", {
  cases <- shared_fixture("context_layer")$augment_context_layer$cases
  # An empty list would make the loop below vacuously succeed.
  expect_gt(length(cases), 0)

  for (case in cases) {
    layer <- if (is.null(case$docs)) {
      NULL
    } else {
      new_context_layer(as.character(unlist(case$docs)))
    }
    sources <- lapply(case$dictionaries, function(spec) {
      dictionary <- if (is.null(spec)) NULL else new_data_dictionary(spec)
      suppressMessages(data_source(sales = test_sales(), dictionary = dictionary))
    })

    augmented <- augment_context_layer(layer, sources)

    if (is.null(case$expected_docs)) {
      expect_null(augmented, info = case$name)
    } else {
      expect_identical(
        context_layer_state(augmented)$docs,
        as.character(unlist(case$expected_docs)),
        info = case$name
      )
    }
  }
})

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

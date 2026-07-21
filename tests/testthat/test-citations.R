test_that("extract_citations pulls quotes in order", {
  text <- paste0(
    "The answer is 42.\n\n",
    "<citation>Revenue excludes tax.</citation>\n",
    "<citation>Orders are counted\nper line item.</citation>"
  )

  expect_equal(
    extract_citations(text),
    c("Revenue excludes tax.", "Orders are counted\nper line item.")
  )
  expect_equal(extract_citations("No citations here."), character())
  expect_equal(extract_citations(character()), character())
})

test_that("answer_citations verifies quotes against the corpus", {
  corpus <- list(
    list(label = "context layer", text = "Revenue excludes tax.\nRefunds are negative rows."),
    list(label = "measure 'order_count'", text = "order_count\nCount of orders, per line item.")
  )
  text <- paste0(
    "<citation>Refunds are negative rows.</citation>",
    "<citation>Count of orders, per line item.</citation>",
    "<citation>Entirely fabricated support.</citation>"
  )

  citations <- answer_citations(text, corpus)

  expect_length(citations, 3)
  expect_equal(citations[[1]]$label, "context layer")
  expect_equal(citations[[2]]$label, "measure 'order_count'")
  expect_false(citations[[3]]$verified)
})

test_that("citation matching forgives reflowed whitespace and typography", {
  corpus <- list(
    list(label = "context layer", text = "Revenue *excludes* tax — always.")
  )

  expect_equal(
    match_citation("Revenue excludes\n  tax - always.", corpus),
    "context layer"
  )
})

test_that("trivial quotes cannot promote an answer", {
  corpus <- list(list(label = "context layer", text = "Revenue excludes tax."))
  expect_true(is.na(match_citation("tax", corpus)))
})

test_that("the citation corpus spans context, measures, and dictionaries", {
  skip_if_not_installed("yaml")
  layer <- context_layer(always = "Fiscal year starts in February.")
  registry <- list(order_count = count_measure_tool())
  path <- withr::local_tempfile(fileext = ".yaml")
  writeLines(
    c(
      '$version: "0.1.0"',
      "name: retail sales",
      "tables:",
      "  - name: sales",
      "    description: One row per order line.",
      "    columns:",
      "      - name: revenue",
      "        description: Booked revenue, net of discounts."
    ),
    path
  )
  source <- data_source(sales = test_sales(), dictionary = path)

  corpus <- build_citation_corpus(
    augment_context_layer(layer, list(source)),
    registry,
    list(source)
  )

  expect_false(is.na(match_citation("Fiscal year starts in February.", corpus)))
  expect_equal(
    match_citation(
      "Count orders, optionally filtered by region and a revenue ceiling.",
      corpus
    ),
    "measure 'order_count'"
  )
  expect_equal(
    match_citation("Booked revenue, net of discounts.", corpus),
    "data dictionary, table 'sales'"
  )
})

test_that("add_citation_request appends once per conversation", {
  tracker <- new.env(parent = emptyenv())
  first <- tool_result("6 rows", title = "Ran SQL", tag = "B")
  second <- tool_result("3 rows", title = "Ran SQL", tag = "B")

  first <- add_citation_request(first, tracker)
  second <- add_citation_request(second, tracker)

  expect_match(first@value, "6 rows")
  expect_match(first@value, "<citation>", fixed = TRUE)
  expect_equal(second@value, "3 rows")
})

test_that("add_citation_request appends ContentText to content lists", {
  tracker <- new.env(parent = emptyenv())
  result <- tool_result(
    list(ellmer::ContentText(text = "output")),
    title = "Ran R code",
    tag = "B"
  )

  result <- add_citation_request(result, tracker)

  expect_length(result@value, 2)
  expect_match(result@value[[2]]@text, "<citation>", fixed = TRUE)
})

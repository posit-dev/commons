test_that("extract_citations pulls quotes in order", {
  text <- paste0(
    "The answer is 42.\n\n",
    "<citation>Revenue excludes tax.</citation>\n",
    "<citation>Orders are counted\nper line item.</citation>"
  )

  expect_equal(
    extract_citations(text),
    list(
      list(quote = "Revenue excludes tax.", reason = NA_character_),
      list(quote = "Orders are counted\nper line item.", reason = NA_character_)
    )
  )
  expect_equal(extract_citations("No citations here."), list())
  expect_equal(extract_citations(character()), list())
})

test_that("extract_citations reads the reason attribute", {
  text <- paste0(
    '<citation reason="Definition followed">Revenue excludes tax.</citation>\n',
    "<citation reason='documented caveat'>Refunds are negative rows.</citation>\n",
    "<citation>No reason given.</citation>"
  )

  citations <- extract_citations(text)

  expect_equal(citations[[1]]$reason, "Definition followed")
  expect_equal(citations[[2]]$reason, "documented caveat")
  expect_true(is.na(citations[[3]]$reason))
})

test_that("extraction skips markup inside code and tolerates tag variants", {
  text <- paste0(
    "Wrap quotes in `<citation>` markup, for example:\n\n",
    "```\n<citation>not a real citation</citation>\n```\n\n",
    "<CITATION >Revenue excludes tax.</citation >"
  )

  expect_equal(
    extract_citations(text),
    list(list(quote = "Revenue excludes tax.", reason = NA_character_))
  )
})

test_that("answer_citations verifies quotes against the corpus", {
  corpus <- list(
    list(label = "context layer", text = "Revenue excludes tax.\nRefunds are negative rows."),
    list(label = "measure 'order_count'", text = "order_count\nCount of orders, per line item.")
  )
  text <- paste0(
    '<citation reason="Refund handling">Refunds are negative rows.</citation>',
    "<citation>Count of orders, per line item.</citation>",
    "<citation>Entirely fabricated support.</citation>"
  )

  citations <- answer_citations(text, corpus)

  expect_length(citations, 3)
  expect_equal(citations[[1]]$label, "context layer")
  expect_equal(citations[[1]]$reason, "Refund handling")
  expect_equal(citations[[2]]$label, "measure 'order_count'")
  expect_true(is.na(citations[[2]]$reason))
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
  fact <- withr::local_tempfile(fileext = ".md")
  writeLines("Fiscal year starts in February.", fact)
  layer <- context_layer(files = fact)
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

test_that("corpus measure text matches multi-source presentation", {
  registry <- list(
    region_revenue = measure(
      "region_revenue",
      "Total revenue for a region.",
      function(region, sales_db) NULL,
      arguments = list(region = ellmer::type_string("The sales region."))
    )
  )
  sources <- list(sales_db = test_source(), crm = test_source())

  corpus <- build_citation_corpus(NULL, registry, sources)

  # search_pool presents a `sources:` line to multi-source agents; a
  # verbatim quote spanning it must verify.
  expect_equal(
    match_citation(
      "Total revenue for a region.\n\nsources: sales_db",
      corpus
    ),
    "measure 'region_revenue'"
  )
})

test_that("dataset-level dictionary prose is citable", {
  skip_if_not_installed("yaml")
  path <- withr::local_tempfile(fileext = ".yaml")
  writeLines(
    c(
      '$version: "0.1.0"',
      "name: retail sales",
      "description: Order and revenue data for a small retailer.",
      "details: Revenue figures exclude tax collected at checkout."
    ),
    path
  )
  source <- data_source(sales = test_sales(), dictionary = path)

  corpus <- build_citation_corpus(NULL, list(), list(source))

  expect_equal(
    match_citation("Order and revenue data for a small retailer.", corpus),
    "data dictionary"
  )
  expect_equal(
    match_citation("Revenue figures exclude tax collected at checkout.", corpus),
    "data dictionary"
  )
})

test_that("add_citation_request appends once per conversation", {
  tracker <- new.env(parent = emptyenv())
  first <- tool_result("6 rows", title = "Ran SQL", tag = "B")
  second <- tool_result("3 rows", title = "Ran SQL", tag = "B")

  first <- add_citation_request(first, tracker)
  second <- add_citation_request(second, tracker)

  expect_match(first@value, "6 rows")
  expect_match(first@value, "<citation ", fixed = TRUE)
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
  expect_match(result@value[[2]]@text, "<citation ", fixed = TRUE)
})

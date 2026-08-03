test_that("dictionary definitions parse and resolve sibling references", {
  src <- definitions_source()
  defs <- src$dictionary$tables$sales$definitions

  expect_named(defs, c("emea", "big_revenue", "region_band"))
  expect_equal(defs$emea$expanded, "region = 'EMEA'")
  expect_equal(
    defs$big_revenue$expanded,
    "SUM(revenue) FILTER (WHERE (region = 'EMEA') AND revenue > 600)"
  )
  expect_equal(
    defs$region_band$expanded,
    "CASE WHEN (region = 'EMEA') THEN 'east' ELSE 'west' END"
  )
})

test_that("sibling references inside string literals are left alone", {
  src <- definitions_source(
    definitions = c(
      "      - name: emea",
      "        type: boolean",
      "        expr: region = 'EMEA'",
      "      - name: emea_label",
      "        type: string",
      "        expr: CASE WHEN emea THEN 'emea market' ELSE 'other' END"
    )
  )
  expect_equal(
    src$dictionary$tables$sales$definitions$emea_label$expanded,
    "CASE WHEN (region = 'EMEA') THEN 'emea market' ELSE 'other' END"
  )
})

test_that("definition envelopes are validated", {
  expect_snapshot(
    error = TRUE,
    definitions_source(
      definitions = c(
        "      - name: emea",
        "        type: boolean"
      )
    )
  )
  expect_snapshot(
    error = TRUE,
    definitions_source(
      definitions = c(
        "      - name: emea",
        "        expr: region = 'EMEA'"
      )
    )
  )
  expect_snapshot(
    error = TRUE,
    definitions_source(
      definitions = c(
        "      - name: not a name",
        "        type: boolean",
        "        expr: region = 'EMEA'"
      )
    )
  )
})

test_that("a definition can't shadow a documented column", {
  expect_snapshot(
    error = TRUE,
    definitions_source(
      definitions = c(
        "      - name: region",
        "        type: boolean",
        "        expr: region = 'EMEA'"
      )
    )
  )
})

test_that("reference cycles error at parse", {
  expect_snapshot(
    error = TRUE,
    definitions_source(
      definitions = c(
        "      - name: chicken",
        "        type: boolean",
        "        expr: egg AND revenue > 0",
        "      - name: egg",
        "        type: boolean",
        "        expr: chicken AND revenue < 10"
      )
    )
  )
})

test_that("the registry records definitions with their roles", {
  src <- definitions_source()
  defs <- registry_defs(sales_registry(src))

  expect_equal(defs$name, c("emea", "big_revenue", "region_band"))
  expect_equal(defs$role, c("filter", "metric", "dimension"))
})

test_that("definitions on unexposed tables abort registry construction", {
  path <- withr::local_tempfile(fileext = ".yaml")
  writeLines(
    c(
      "tables:",
      "  - name: elsewhere",
      "    definitions:",
      "      - name: emea",
      "        type: boolean",
      "        expr: region = 'EMEA'"
    ),
    path
  )
  src <- data_source(sales = test_sales(), dictionary = path)
  expect_snapshot(error = TRUE, definitions_registry(list(sales_db = src)))
})

test_that("boolean aggregates are rejected at parse", {
  expect_error(
    definitions_source(
      definitions = c(
        "      - name: big",
        "        type: boolean",
        "        expr: SUM(revenue) > 1000"
      )
    ),
    "can't filter rows"
  )
})

test_that("expansion splices governed expressions into model SQL", {
  src <- definitions_source()
  registry <- sales_registry(src)

  expansion <- expand_for_run_sql(
    registry,
    list(sales_db = src),
    NULL,
    "SELECT {{region_band}} AS band, {{big_revenue}} AS big FROM sales GROUP BY {{region_band}}"
  )
  expect_equal(
    expansion$sql,
    paste0(
      "SELECT (CASE WHEN (region = 'EMEA') THEN 'east' ELSE 'west' END) AS band, ",
      "(SUM(revenue) FILTER (WHERE (region = 'EMEA') AND revenue > 600)) AS big ",
      "FROM sales GROUP BY (CASE WHEN (region = 'EMEA') THEN 'east' ELSE 'west' END)"
    )
  )
  expect_equal(expansion$applied$name, c("region_band", "big_revenue"))

  # EMEA revenues over 600 in test_sales(): 1200 + 750.
  result <- source_query(src, expansion$sql)
  expect_equal(result$big[result$band == "east"], 1950)
})

test_that("SQL without tokens passes through expansion untouched", {
  src <- definitions_source()
  registry <- sales_registry(src)
  sql <- "SELECT count(*) FROM sales"
  expansion <- expand_for_run_sql(
    registry,
    list(sales_db = src),
    NULL,
    sql
  )
  expect_identical(expansion$sql, sql)
  expect_null(expansion$applied)
})

test_that("token resolution errors are actionable", {
  src <- definitions_source()
  registry <- sales_registry(src)
  records <- registry_defs(registry)

  expect_snapshot(
    error = TRUE,
    expand_definitions("SELECT {{nope}} FROM sales", records)
  )
  expect_snapshot(
    error = TRUE,
    expand_definitions("SELECT {{emea}} FROM elsewhere", records)
  )
})

test_that("same-named definitions on several tables disambiguate by scope", {
  path <- withr::local_tempfile(fileext = ".yaml")
  writeLines(
    c(
      "tables:",
      "  - name: sales",
      "    definitions:",
      "      - name: deduplicated",
      "        type: boolean",
      "        expr: revenue > 0",
      "  - name: reps",
      "    definitions:",
      "      - name: deduplicated",
      "        type: boolean",
      "        expr: n_sales > 0"
    ),
    path
  )
  src <- data_source(
    sales = test_sales(),
    reps = data.frame(rep = "Ada", n_sales = 3L),
    dictionary = path
  )
  registry <- sales_registry(src)
  records <- registry_defs(registry)

  scoped <- expand_definitions(
    "SELECT count(*) FROM sales WHERE {{deduplicated}}",
    records
  )
  expect_match(scoped$sql, "revenue > 0", fixed = TRUE)

  expect_snapshot(
    error = TRUE,
    expand_definitions(
      "SELECT count(*) FROM sales JOIN reps USING (rep) WHERE {{deduplicated}}",
      records
    )
  )
  qualified <- expand_definitions(
    "SELECT count(*) FROM sales JOIN reps USING (rep) WHERE {{sales.deduplicated}}",
    records
  )
  expect_match(qualified$sql, "revenue > 0", fixed = TRUE)
})

test_that("run_sql results note the definitions applied", {
  src <- definitions_source()
  registry <- sales_registry(src)
  expansion <- expand_for_run_sql(
    registry,
    list(sales_db = src),
    NULL,
    "SELECT count(*) AS n FROM sales WHERE {{emea}}"
  )
  res <- run_sql_tool(src, expansion$sql, applied = expansion$applied)
  expect_match(res@value, "Applied governed definitions", fixed = TRUE)
  expect_match(res@value, "{{emea}}", fixed = TRUE)
  expect_match(res@value, "region = 'EMEA'", fixed = TRUE)
})

test_that("the system prompt carries a governed-definitions index", {
  src <- definitions_source()
  registry <- sales_registry(src)
  prompt <- commons_system_prompt(
    list(sales_db = src),
    default_system_prompt(),
    registry
  )
  expect_match(prompt, "# Governed definitions", fixed = TRUE)
  expect_match(
    prompt,
    "- sales: filters `{{emea}}`; dimensions `{{region_band}}`; metrics `{{big_revenue}}`",
    fixed = TRUE
  )
  # Depth is first-touch and search content, not ambient: neither
  # expansions nor descriptions appear in the prompt.
  expect_no_match(prompt, "region = 'EMEA'", fixed = TRUE)
  expect_no_match(prompt, "EMEA rows only", fixed = TRUE)
})

test_that("a definition's label is its index hint", {
  src <- definitions_source(
    definitions = c(
      "      - name: emea",
      "        type: boolean",
      "        label: EMEA rows",
      "        description: The region = 'EMEA' slice of orders.",
      "        expr: region = 'EMEA'"
    )
  )
  registry <- sales_registry(src)
  text <- definition_index_text(registry)
  expect_match(text, "`{{emea}}` (EMEA rows)", fixed = TRUE)
  expect_no_match(text, "slice of orders", fixed = TRUE)
})

test_that("the prompt section caps like the glossary", {
  registry <- sales_registry(definitions_source(many_definitions()))
  expect_true(definitions_overflow(registry))
  text <- commons_system_prompt(
    list(sales_db = definitions_source(many_definitions())),
    default_system_prompt(),
    registry
  )
  expect_lt(nchar(text), 6000)
  expect_match(text, "More definitions arrive", fixed = TRUE)

  expect_false(definitions_overflow(sales_registry(definitions_source())))
})

test_that("first touch delivers a table's definitions with expansions", {
  src <- definitions_source()
  entry <- dictionary_entry_text(src$dictionary, "sales")
  expect_match(entry, "Governed definitions", fixed = TRUE)
  expect_match(entry, "Expands to `(region = 'EMEA')`", fixed = TRUE)
})

test_that("definitions are indexed as context chunks", {
  src <- definitions_source()
  chunks <- dictionary_context_chunks(src$dictionary)
  hit <- grepl("Governed definition `{{big_revenue}}`", chunks, fixed = TRUE)
  expect_true(any(hit))
  expect_match(chunks[hit], "SUM(revenue)", fixed = TRUE)
})

test_that("run_sql's description matches the agent's composition", {
  src <- definitions_source()
  registry <- sales_registry(src)
  empty <- definitions_registry(list(test_source()))

  expect_match(run_sql_description(registry), "{{name}} tokens", fixed = TRUE)
  expect_no_match(run_sql_description(registry), "registered measure")
  expect_no_match(run_sql_description(empty), "tokens")
  expect_match(
    run_sql_description(empty, measures = list(count_measure_tool())),
    "registered measure"
  )
})

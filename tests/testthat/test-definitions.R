local_definitions_dict <- function(
  definitions = c(
    "      - name: emea",
    "        type: boolean",
    "        description: EMEA rows only.",
    "        expr: region = 'EMEA'",
    "      - name: big_revenue",
    "        type: number(quantity)",
    "        description: Revenue over big EMEA orders.",
    "        expr: SUM(revenue) FILTER (WHERE emea AND revenue > 600)",
    "      - name: region_band",
    "        type: string",
    "        description: Coarse region grouping.",
    "        expr: CASE WHEN emea THEN 'east' ELSE 'west' END"
  ),
  env = parent.frame()
) {
  path <- withr::local_tempfile(fileext = ".yaml", .local_envir = env)
  writeLines(
    c(
      "name: retail sales",
      "description: Order and revenue data for a small retailer.",
      "tables:",
      "  - name: sales",
      "    description: One row per order line.",
      "    columns:",
      "      - name: revenue",
      "        type: number(quantity)",
      "      - name: region",
      "        type: enum",
      "        values: [Americas, APAC, EMEA]",
      "    definitions:",
      definitions
    ),
    path
  )
  path
}

definitions_source <- function(...) {
  data_source(sales = test_sales(), dictionary = local_definitions_dict(...))
}

validated_registry <- function(src) {
  registry <- definitions_registry(list(sales_db = src))
  validate_eager_definitions(registry, list(sales_db = src))
  registry
}

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

test_that("the registry records definitions with roles from validation", {
  src <- definitions_source()
  registry <- validated_registry(src)

  records <- registry_records(registry)
  expect_length(records, 3)
  roles <- vapply(records, function(r) r$role, character(1))
  names(roles) <- vapply(records, function(r) r$name, character(1))
  expect_equal(
    roles,
    c(emea = "filter", big_revenue = "metric", region_band = "dimension")
  )
  expect_true(all(vapply(records, function(r) r$validated, logical(1))))
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

test_that("validation names the definition that fails to bind", {
  src <- definitions_source(
    definitions = c(
      "      - name: emea",
      "        type: boolean",
      "        expr: reggion = 'EMEA'"
    )
  )
  expect_error(
    validated_registry(src),
    "\"emea\".*does not bind",
    class = "rlang_error"
  )
})

test_that("validation checks the declared type against the bound type", {
  src <- definitions_source(
    definitions = c(
      "      - name: emea",
      "        type: boolean",
      "        expr: revenue + 1"
    )
  )
  expect_error(validated_registry(src), "declared \"boolean\"")
})

test_that("boolean aggregates are rejected at validation", {
  src <- definitions_source(
    definitions = c(
      "      - name: big",
      "        type: boolean",
      "        expr: SUM(revenue) > 1000"
    )
  )
  expect_error(validated_registry(src), "can't filter rows")
})

test_that("expansion splices governed expressions into model SQL", {
  src <- definitions_source()
  registry <- validated_registry(src)

  expansion <- expand_for_run_sql(
    registry,
    list(sales_db = src),
    src,
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
  expect_equal(
    vapply(expansion$applied, function(r) r$name, character(1)),
    c("region_band", "big_revenue")
  )

  # EMEA revenues over 600 in test_sales(): 1200 + 750.
  result <- source_query(src, expansion$sql)
  expect_equal(result$big[result$band == "east"], 1950)
})

test_that("SQL without tokens passes through expansion untouched", {
  src <- definitions_source()
  registry <- validated_registry(src)
  sql <- "SELECT count(*) FROM sales"
  expansion <- expand_for_run_sql(registry, list(sales_db = src), src, NULL, sql)
  expect_identical(expansion$sql, sql)
  expect_length(expansion$applied, 0)
})

test_that("token resolution errors are actionable", {
  src <- definitions_source()
  registry <- validated_registry(src)
  records <- registry_records(registry)

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
  registry <- validated_registry(src)
  records <- registry_records(registry)

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

test_that("board-source definitions validate at first expansion", {
  board <- board_with_pins(sales = test_sales())
  path <- local_definitions_dict(
    definitions = c(
      "      - name: emea",
      "        type: boolean",
      "        expr: reggion = 'EMEA'"
    )
  )
  src <- data_source(board, tables = c(sales = "sales"), dictionary = path)
  registry <- definitions_registry(list(sales_db = src))

  # Lazy source: construction-time validation skips it, so no error yet.
  validate_eager_definitions(registry, list(sales_db = src))
  expect_false(registry_records(registry)[[1]]$validated)

  expect_error(
    expand_for_run_sql(
      registry,
      list(sales_db = src),
      src,
      NULL,
      "SELECT count(*) FROM sales WHERE {{emea}}"
    ),
    "does not bind"
  )
})

test_that("run_sql results note the definitions applied", {
  src <- definitions_source()
  registry <- validated_registry(src)
  expansion <- expand_for_run_sql(
    registry,
    list(sales_db = src),
    src,
    NULL,
    "SELECT count(*) AS n FROM sales WHERE {{emea}}"
  )
  res <- run_sql_tool(src, expansion$sql, applied = expansion$applied)
  expect_match(res@value, "Applied governed definitions", fixed = TRUE)
  expect_match(res@value, "{{emea}}", fixed = TRUE)
  expect_match(res@value, "region = 'EMEA'", fixed = TRUE)
})

test_that("the system prompt carries a governed-definitions section", {
  src <- definitions_source()
  registry <- validated_registry(src)
  prompt <- commons_system_prompt(
    list(sales_db = src),
    "You are a data analyst.",
    registry
  )
  expect_match(prompt, "# Governed definitions", fixed = TRUE)
  expect_match(prompt, "`{{emea}}` (sales): EMEA rows only.", fixed = TRUE)
  expect_match(prompt, "Filters (boolean; use in WHERE)", fixed = TRUE)
  # Full expansions are first-touch and search content, not ambient.
  expect_no_match(prompt, "region = 'EMEA'", fixed = TRUE)
})

test_that("the prompt section caps like the glossary", {
  many <- unlist(lapply(1:200, function(i) {
    c(
      sprintf("      - name: filter_%03d", i),
      "        type: boolean",
      sprintf("        expr: revenue > %d", i),
      sprintf("        description: Filter number %d of many.", i)
    )
  }))
  src <- definitions_source(definitions = many)
  registry <- validated_registry(src)
  text <- definitions_prompt_text(registry)
  expect_lt(nchar(text), 6000)
  expect_match(text, "More definitions arrive", fixed = TRUE)
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
  registry <- validated_registry(src)
  empty <- definitions_registry(list(test_source()))

  expect_match(run_sql_description(registry), "{{name}} tokens", fixed = TRUE)
  expect_no_match(run_sql_description(registry), "registered measure")
  expect_no_match(run_sql_description(empty), "tokens")
  expect_match(
    run_sql_description(empty, measures = list(count_measure_tool())),
    "registered measure"
  )
})

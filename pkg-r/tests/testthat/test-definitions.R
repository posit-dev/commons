test_that("dictionary definitions use landed export records", {
  src <- definitions_source()
  defs <- data_source_state(src)$dictionary$tables$sales$definitions

  expect_named(defs, c("emea", "big_revenue", "region_band"))
  expect_equal(defs$emea$expression, "region = 'EMEA'")
  expect_equal(defs$emea$kind, "filter")
  expect_equal(defs$emea$type, "boolean")
  expect_equal(defs$emea$target, "SQL(duckdb)")
  expect_equal(defs$emea$sql, '"region" = \'EMEA\'')
  expect_equal(defs$big_revenue$definitions, "emea")
  expect_equal(defs$big_revenue$columns, "revenue")
  expect_match(defs$big_revenue$sql, '"region" = \'EMEA\'', fixed = TRUE)
  expect_match(
    defs$big_revenue$translations[[1]]$code,
    '"emea"',
    fixed = TRUE
  )
})

test_that("dictionary normalization attaches export metadata before binding", {
  dictionary <- data_dictionary(local_definitions_dict())
  definition <- dictionary$tables$sales$definitions$big_revenue

  expect_equal(definition$kind, "metric")
  expect_equal(definition$type, "number")
  expect_equal(
    definition$expression,
    "SUM(CASE WHEN emea AND revenue > 600 THEN revenue ELSE 0 END)"
  )
  expect_equal(definition$definitions, "emea")
  expect_equal(definition$translations[[1]]$target, "SQL(duckdb)")
  expect_null(definition$target)
  expect_null(definition$sql)
  expect_length(attr(dictionary, "definition_export")$tables, 1L)
})

test_that("definition envelopes infer types and accept general names", {
  src <- definitions_source(
    definitions = c(
      "      - name: not a name",
      "        expr: region = 'EMEA'"
    )
  )

  definition <- data_source_state(src)$dictionary$tables$sales$definitions[["not a name"]]
  expect_equal(definition$type, "boolean")
  expect_equal(definition$kind, "filter")

  expect_error(
    definitions_source(definitions = "      - name: missing expression"),
    "needs a non-empty.*expr"
  )
})

test_that("a definition cannot shadow a documented column", {
  expect_error(
    definitions_source(
      definitions = c(
        "      - name: region",
        "        expr: region = 'EMEA'"
      )
    ),
    "share names with columns"
  )
})

test_that("reference cycles fail during dictionary validation", {
  expect_error(
    definitions_source(
      definitions = c(
        "      - name: chicken",
        "        expr: egg AND revenue > 0",
        "      - name: egg",
        "        expr: chicken AND revenue < 10"
      )
    ),
    "cycle"
  )
})

test_that("the registry contains compiled definition metadata", {
  defs <- registry_defs(sales_registry(definitions_source()))

  expect_equal(defs$name, c("emea", "big_revenue", "region_band"))
  expect_equal(defs$kind, c("filter", "metric", "derived"))
  expect_equal(defs$type, c("boolean", "number", "string"))
  expect_equal(defs$target, rep("SQL(duckdb)", 3))
  expect_true(all(nzchar(defs$sql)))
  expect_equal(defs$definitions[[2]], "emea")
  expect_equal(defs$columns[[2]], "revenue")
  expect_length(defs$translations[[2]], 3L)
  expect_false(any(defs$mixed_grain))
})

test_that("definitions on unexposed tables fail source construction", {
  path <- withr::local_tempfile(fileext = ".yaml")
  writeLines(
    c(
      "tables:",
      "  - name: elsewhere",
      "    definitions:",
      "      - name: answer",
      "        expr: \"42\""
    ),
    path
  )

  expect_error(
    data_source(sales = test_sales(), dictionary = path),
    "does not expose"
  )
})

test_that("definitions reject an unsupported source backend", {
  dictionary <- data_dictionary(local_definitions_dict())
  con <- structure(list(), class = c("unknown_connection", "DBIConnection"))

  expect_error(
    new_data_source(
      con,
      tables = "sales",
      owned = FALSE,
      dictionary = dictionary
    ),
    regexp = "emea.*unknown",
    ignore.case = TRUE
  )
})

test_that("boolean aggregates and constants are metrics", {
  src <- definitions_source(
    definitions = c(
      "      - name: any_emea",
      "        expr: ANY(region = 'EMEA')",
      "      - name: answer",
      "        expr: \"42\""
    )
  )
  defs <- data_source_state(src)$dictionary$tables$sales$definitions

  expect_equal(defs$any_emea$kind, "metric")
  expect_equal(defs$any_emea$type, "boolean")
  expect_equal(defs$answer$kind, "metric")
  expect_equal(defs$answer$type, "number")

  store <- new_handle_store()
  call_metrics_impl(
    definitions_registry(list(sales_db = src)),
    list(sales_db = src),
    store,
    metrics = "answer"
  )
  expect_equal(get_handle(store, "r1")$answer, 42)
})

test_that("run_sql expansion uses composed source SQL", {
  src <- definitions_source()
  registry <- sales_registry(src)

  expansion <- expand_for_run_sql(
    registry,
    list(sales_db = src),
    NULL,
    paste0(
      "SELECT {{region_band}} AS band, {{big_revenue}} AS big ",
      "FROM sales GROUP BY {{region_band}}"
    )
  )

  expect_match(expansion$sql, '"region" = \'EMEA\'', fixed = TRUE)
  expect_match(expansion$sql, 'sum(CASE WHEN', fixed = TRUE)
  expect_no_match(expansion$sql, '"emea"', fixed = TRUE)
  expect_equal(expansion$applied$name, c("region_band", "big_revenue"))

  result <- source_query(src, expansion$sql)
  expect_equal(result$big[result$band == "east"], 1950)
})

test_that("SQL without tokens passes through expansion untouched", {
  src <- definitions_source()
  sql <- "SELECT count(*) FROM sales"
  expansion <- expand_for_run_sql(
    sales_registry(src),
    list(sales_db = src),
    NULL,
    sql
  )

  expect_identical(expansion$sql, sql)
  expect_null(expansion$applied)
})

test_that("token resolution errors are actionable", {
  records <- registry_defs(sales_registry(definitions_source()))

  expect_error(
    expand_definitions("SELECT {{nope}} FROM sales", records),
    "No governed definition"
  )
  expect_error(
    expand_definitions("SELECT {{emea}} FROM elsewhere", records),
    "does not appear"
  )
  expect_error(
    expand_definitions("SELECT {{sales::emea}} FROM elsewhere", records),
    "does not appear"
  )
  expect_error(
    expand_definitions("SELECT {{sales.emea}} FROM elsewhere", records),
    "does not appear"
  )

  constant <- definitions_source(
    definitions = c(
      "      - name: answer",
      "        expr: \"42\""
    )
  )
  constant_records <- registry_defs(sales_registry(constant))
  expect_error(
    expand_definitions(
      "SELECT {{sales::answer}} FROM elsewhere",
      constant_records
    ),
    "does not appear"
  )
})

test_that("same-named definitions disambiguate by table scope", {
  path <- withr::local_tempfile(fileext = ".yaml")
  writeLines(
    c(
      "tables:",
      "  - name: sales",
      "    columns:",
      "      - name: revenue",
      "        type: number",
      "    definitions:",
      "      - name: positive",
      "        expr: revenue > 0",
      "  - name: reps",
      "    columns:",
      "      - name: n_sales",
      "        type: number",
      "    definitions:",
      "      - name: positive",
      "        expr: n_sales > 0"
    ),
    path
  )
  src <- data_source(
    sales = test_sales(),
    reps = data.frame(rep = "Ada", n_sales = 3L),
    dictionary = path
  )
  records <- registry_defs(sales_registry(src))

  scoped <- expand_definitions(
    "SELECT count(*) FROM sales WHERE {{positive}}",
    records
  )
  expect_match(scoped$sql, '"revenue" > 0', fixed = TRUE)

  expect_error(
    expand_definitions(
      "SELECT count(*) FROM sales JOIN reps USING (rep) WHERE {{positive}}",
      records
    ),
    "ambiguous"
  )
  qualified <- expand_definitions(
    paste(
      "SELECT count(*) FROM sales JOIN reps USING (rep)",
      "WHERE {{sales::positive}}"
    ),
    records
  )
  expect_match(qualified$sql, '"revenue" > 0', fixed = TRUE)

  legacy <- expand_definitions(
    "SELECT count(*) FROM sales WHERE {{sales.positive}}",
    records
  )
  expect_match(legacy$sql, '"revenue" > 0', fixed = TRUE)
})

test_that("tokens support spaces, keywords, and dots", {
  path <- withr::local_tempfile(fileext = ".yaml")
  writeLines(
    c(
      "tables:",
      "  - name: sales.data",
      "    columns:",
      "      - name: revenue",
      "        type: number",
      "    definitions:",
      "      - name: gross margin",
      "        expr: revenue / 2",
      "      - name: select",
      "        expr: revenue > 0",
      "      - name: gross.margin",
      "        expr: revenue > 100"
    ),
    path
  )
  src <- data_source(`sales.data` = test_sales(), dictionary = path)
  records <- registry_defs(definitions_registry(list(sales_db = src)))

  expansion <- expand_definitions(
    paste0(
      'SELECT {{gross margin}}, {{select}}, {{sales.data::gross.margin}} ',
      'FROM "sales.data"'
    ),
    records
  )
  expect_match(expansion$sql, '"revenue" / 2', fixed = TRUE)
  expect_match(expansion$sql, '"revenue" > 0', fixed = TRUE)
  expect_match(expansion$sql, '"revenue" > 100', fixed = TRUE)
})

test_that("run_sql results report source, selected SQL, and notes", {
  src <- definitions_source()
  expansion <- expand_for_run_sql(
    sales_registry(src),
    list(sales_db = src),
    NULL,
    "SELECT {{big_revenue}} AS revenue FROM sales"
  )
  result <- run_sql_tool(src, expansion$sql, applied = expansion$applied)

  expect_match(result@value, "Applied governed definitions", fixed = TRUE)
  expect_no_match(result@value, "Expression:", fixed = TRUE)
  expect_no_match(result@value, ": expression `", fixed = TRUE)
  expect_no_match(result@value, "SUM(CASE WHEN emea", fixed = TRUE)
  expect_match(result@value, "SQL(duckdb)", fixed = TRUE)
  expect_match(result@value, "Translation notes", fixed = TRUE)
})

test_that("the system prompt indexes landed definition kinds", {
  src <- definitions_source()
  prompt <- commons_system_prompt(
    list(sales_db = src),
    definitions = sales_registry(src)
  )

  expect_match(prompt, "# Governed definitions", fixed = TRUE)
  expect_match(prompt, "`{{table::name}}`", fixed = TRUE)
  expect_match(
    prompt,
    "- sales: filters `{{emea}}`; derived `{{region_band}}`; metrics `{{big_revenue}}`",
    fixed = TRUE
  )
  expect_no_match(prompt, "region = 'EMEA'", fixed = TRUE)
  expect_no_match(prompt, "EMEA rows only", fixed = TRUE)
})

test_that("a definition label is its index hint", {
  src <- definitions_source(
    definitions = c(
      "      - name: emea",
      "        label: EMEA rows",
      "        description: The EMEA slice of orders.",
      "        expr: region = 'EMEA'"
    )
  )
  text <- definition_index_text(sales_registry(src))

  expect_match(text, "`{{emea}}` (EMEA rows)", fixed = TRUE)
  expect_no_match(text, "slice of orders", fixed = TRUE)
})

test_that("the prompt definition index is capped", {
  src <- definitions_source(many_definitions())
  registry <- sales_registry(src)

  expect_true(definitions_overflow(registry))
  prompt <- commons_system_prompt(
    list(sales_db = src),
    definitions = registry
  )
  expect_lt(nchar(prompt), 6000)
  expect_match(prompt, "More definitions arrive", fixed = TRUE)
  expect_false(definitions_overflow(sales_registry(definitions_source())))
})

test_that("first touch shows compiled SQL without expression source", {
  src <- definitions_source()
  entry <- dictionary_entry_text(data_source_state(src)$dictionary, "sales")

  expect_match(entry, "Governed definitions", fixed = TRUE)
  expect_no_match(entry, "Expression:", fixed = TRUE)
  expect_no_match(entry, "region = 'EMEA'", fixed = TRUE)
  expect_match(entry, "Selected SQL(duckdb)", fixed = TRUE)
  expect_match(entry, '"region" = \'EMEA\'', fixed = TRUE)
  expect_match(entry, "Translation notes", fixed = TRUE)
})

test_that("definitions are indexed as context chunks", {
  src <- definitions_source()
  chunks <- dictionary_context_chunks(data_source_state(src)$dictionary)
  hit <- grepl("Governed definition `{{big_revenue}}`", chunks, fixed = TRUE)

  expect_true(any(hit))
  expect_no_match(chunks[hit], "Expression:", fixed = TRUE)
  expect_no_match(chunks[hit], "SUM(CASE WHEN emea", fixed = TRUE)
  expect_match(chunks[hit], "Selected SQL(duckdb)", fixed = TRUE)
})

test_that("run_sql description explains compiled tokens", {
  registry <- sales_registry(definitions_source())
  empty <- definitions_registry(list(test_source()))

  expect_match(run_sql_description(registry), "{{name}} tokens", fixed = TRUE)
  expect_match(run_sql_description(registry), "{{table::name}}", fixed = TRUE)
  expect_match(run_sql_description(registry), "compiled", fixed = TRUE)
  expect_no_match(run_sql_description(empty), "tokens")
})

test_that("token expansion matches the shared contract", {
  spec <- shared_fixture("definition-rendering")$expand_tokens
  expect_gt(length(spec$cases), 0)

  for (case in spec$cases) {
    defs <- fixture_registry(unlist(case$records))$defs
    if (is.null(case$expanded)) {
      expect_error(
        expand_definitions(case$sql, defs),
        definition_refusal_pattern[[case$reason]],
        info = case$name
      )
      next
    }
    expansion <- expand_definitions(case$sql, defs)
    expect_identical(expansion$sql, case$expanded, info = case$name)
    expect_identical(
      as.character(expansion$applied$name),
      as.character(unlist(case$applied)),
      info = case$name
    )
  }
})

test_that("the definition gist matches the shared contract", {
  spec <- shared_fixture("definition-rendering")$gist
  expect_gt(length(spec$cases), 0)

  for (case in spec$cases) {
    expect_identical(
      unname(definition_gist(list(fixture_definition(case$record)))),
      case$expected,
      info = case$name
    )
  }
})

test_that("the definition index matches the shared contract", {
  spec <- shared_fixture("definition-rendering")$index
  expect_gt(length(spec$cases), 0)

  for (case in spec$cases) {
    registry <- fixture_registry(unlist(case$records))
    expect_identical(
      definition_index_text(registry, cap_chars = case$cap_chars),
      case$text,
      info = case$name
    )
    expect_identical(
      definitions_overflow(registry, cap_chars = case$cap_chars),
      case$overflows,
      info = case$name
    )
  }
})

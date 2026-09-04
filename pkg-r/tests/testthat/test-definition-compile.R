definition_compile_fixture <- function(name, source) {
  path <- definition_fixture_path(name)
  definition_compile_source(yaml::read_yaml(path), source)
}

definition_compiled_table <- function(compiled) {
  definitions <- compiled$tables[[1]]$definitions
  stats::setNames(
    definitions,
    vapply(definitions, `[[`, character(1), "name")
  )
}

definition_translation <- function(definition, target) {
  targets <- vapply(definition$translations, `[[`, character(1), "target")
  definition$translations[[match(target, targets)]]
}

definition_mock_source <- function(table = "values", bindings = NULL) {
  new_data_source(
    structure(list(), class = "mock_connection"),
    tables = table,
    owned = FALSE,
    definition_bindings = bindings
  )
}

test_that("definitions compile and compose for a DuckDB source", {
  skip_if_not_installed("yaml")
  source <- data_source(
    orders = data.frame(
      status_cd = c(10, 90),
      order_total = c(100, 200),
      tile_size = c("Enterprise-1", "Consumer")
    )
  )
  compiled <- definition_compile_fixture("core.yaml", source)
  definitions <- definition_compiled_table(compiled)

  expect_equal(compiled$target, "SQL(duckdb)")
  expect_equal(
    definition_translation(
      definitions$enterprise_revenue,
      "SQL(duckdb)"
    )$code,
    'sum(CASE WHEN "is_enterprise" THEN "order_total" ELSE 0 END)'
  )

  net_revenue <- DBI::dbGetQuery(
    data_source_state(source)$con,
    paste0(
      "SELECT ",
      definitions$net_revenue$sql,
      ' AS value FROM "orders"'
    )
  )
  enterprise_revenue <- DBI::dbGetQuery(
    data_source_state(source)$con,
    paste0(
      "SELECT ",
      definitions$enterprise_revenue$sql,
      ' AS value FROM "orders"'
    )
  )
  expect_equal(net_revenue$value, 100)
  expect_equal(enterprise_revenue$value, 100)
})

test_that("composed SQL and notes match the shared contract", {
  skip_if_not_installed("yaml")
  fixture <- shared_fixture("definitions")$composed
  checked <- 0L
  for (path in definition_fixture_paths("valid")) {
    raw <- yaml::read_yaml(path)
    tables <- vapply(raw$tables, `[[`, "", "name")
    frames <- stats::setNames(
      lapply(tables, function(table) data.frame(x = 1)),
      tables
    )
    source <- do.call(data_source, frames)
    compiled <- definition_compile_source(raw, source)
    expected <- fixture[[basename(path)]]
    for (table in compiled$tables) {
      for (definition in table$definitions) {
        key <- paste0(table$name, "::", definition$name)
        notes <- expected[[key]]$notes
        expect_equal(definition$sql, expected[[key]]$sql)
        expect_equal(
          definition$notes,
          if (length(notes)) unlist(notes) else character(0)
        )
        checked <- checked + 1L
      }
    }
  }
  expect_equal(checked, 42L)
})

test_that("source compilation rejects metrics over mixed-grain definitions", {
  expect_error(
    definitions_source(
      definitions = c(
        "      - name: above_minimum",
        "        expr: revenue > MIN(revenue)",
        "      - name: inherited_mixed",
        "        expr: NOT above_minimum",
        "      - name: mixed_metric",
        "        expr: ANY(inherited_mixed)"
      )
    ),
    "requires a subquery rewrite"
  )
})

test_that("warehouse lowering matches the shared contract", {
  skip_if_not_installed("yaml")
  spec <- shared_fixture("definition-warehouse-sql")
  cases <- spec$cases
  expect_gt(length(cases), 0)
  checked <- 0

  for (filename in names(cases)) {
    file_cases <- cases[[filename]]
    # The source only has to expose the tables the cases name; the corpus
    # dictionary supplies everything else.
    tables <- unique(vapply(
      names(file_cases),
      function(key) strsplit(key, "::", fixed = TRUE)[[1]][[1]],
      character(1)
    ))
    frames <- stats::setNames(
      lapply(tables, function(ignored) data.frame(row = 1)),
      tables
    )
    source <- do.call(data_source, frames)
    definitions <- definition_compiled_table(
      definition_compile_fixture(filename, source)
    )

    for (key in names(file_cases)) {
      name <- strsplit(key, "::", fixed = TRUE)[[1]][[2]]
      for (target in names(file_cases[[key]])) {
        # `[[` throughout: `$` partial-matches, so `expected$code` would
        # silently return `code_contains` on a case that has no exact code.
        expected <- file_cases[[key]][[target]]
        actual <- definition_translation(definitions[[name]], target)
        info <- paste(filename, key, target)
        if (!is.null(expected[["code"]])) {
          expect_equal(actual$code, expected[["code"]], info = info)
        }
        for (fragment in expected[["code_contains"]] %||% character()) {
          expect_true(grepl(fragment, actual$code, fixed = TRUE), info = info)
        }
        for (fragment in expected[["notes_contain"]] %||% character()) {
          expect_true(
            any(grepl(fragment, actual$notes, fixed = TRUE)),
            info = info
          )
        }
        checked <- checked + 1L
      }
    }
  }

  expect_gte(checked, 20L)
})

test_that("source selection binds authored warehouse identifiers", {
  skip_if_not_installed("yaml")
  local_mocked_bindings(
    is_snowflake_connection = function(con) TRUE,
    is_databricks_connection = function(con) FALSE
  )
  bindings <- list(
    tables = c(orders = "ANALYTICS.PUBLIC.ORDERS"),
    columns = list(
      orders = c(
        status_cd = "STATUS_CD",
        order_total = "ORDER_TOTAL",
        tile_size = "TILE_SIZE"
      )
    ),
    strict = TRUE
  )
  source <- definition_mock_source("ANALYTICS.PUBLIC.ORDERS", bindings)
  compiled <- definition_compile_fixture("core.yaml", source)
  definitions <- definition_compiled_table(compiled)

  expect_equal(compiled$target, "SQL(snowflake)")
  expect_named(compiled$tables, "ANALYTICS.PUBLIC.ORDERS")
  expect_equal(
    definitions$list_price$sql,
    '"ORDER_TOTAL" * 1.2'
  )
  expect_equal(
    definition_translation(definitions$list_price, "SQL(snowflake)")$code,
    '"order_total" * 1.2'
  )
  expect_match(
    definitions$enterprise_revenue$sql,
    '"TILE_SIZE"',
    fixed = TRUE
  )
})

test_that("missing warehouse bindings fail before SQL can run", {
  skip_if_not_installed("yaml")
  local_mocked_bindings(
    is_snowflake_connection = function(con) TRUE,
    is_databricks_connection = function(con) FALSE
  )
  bindings <- list(
    tables = c(orders = "ANALYTICS.PUBLIC.ORDERS"),
    columns = list(
      orders = c(
        status_cd = "STATUS_CD",
        order_total = "ORDER_TOTAL",
        tile_size = NA_character_
      )
    ),
    strict = TRUE
  )

  expect_error(
    definition_compile_fixture(
      "core.yaml",
      definition_mock_source("ANALYTICS.PUBLIC.ORDERS", bindings)
    ),
    "authored column.*tile_size"
  )
})

test_that("the source backend selects the destination target", {
  skip_if_not_installed("yaml")
  local_mocked_bindings(
    is_snowflake_connection = function(con) FALSE,
    is_databricks_connection = function(con) TRUE
  )
  source <- definition_mock_source("values")
  compiled <- definition_compile_fixture("functions.yaml", source)

  expect_equal(compiled$target, "SQL(databricks)")
  expect_match(
    definition_compiled_table(compiled)$strings$sql,
    "`text`",
    fixed = TRUE
  )
})

test_that("unknown source backends reject definitions only when present", {
  source <- definition_mock_source("values")
  empty <- list(tables = list(list(name = "values")))
  defined <- list(
    tables = list(list(
      name = "values",
      columns = list(list(name = "number", type = "number(quantity)")),
      definitions = list(list(name = "positive", expr = "number > 0"))
    ))
  )

  expect_null(definition_compile_source(empty, source)$target)
  expect_error(
    definition_compile_source(defined, source),
    "Definitions.*positive.*cannot be compiled"
  )
})

test_that("unsupported translations are explicit and selected errors abort", {
  raw <- list(
    tables = list(list(
      name = "values",
      definitions = list(list(
        name = "duration",
        expr = "interval(2, days)"
      ))
    ))
  )
  duckdb <- data_source(values = data.frame(row = 1))
  definitions <- definition_compiled_table(
    definition_compile_source(raw, duckdb)
  )

  expect_match(
    definition_translation(definitions$duration, "SQL(snowflake)")$error,
    "standalone interval"
  )
  expect_match(
    definition_translation(definitions$duration, "SQL(databricks)")$error,
    "standalone interval"
  )

  local_mocked_bindings(
    is_snowflake_connection = function(con) TRUE,
    is_databricks_connection = function(con) FALSE
  )
  expect_error(
    definition_compile_source(raw, definition_mock_source("values")),
    "cannot be compiled for.*SQL\\(snowflake\\)"
  )
})

test_that("target restrictions stay on their translation records", {
  raw <- list(
    tables = list(list(
      name = "values",
      columns = list(list(name = "number", type = "number(quantity)")),
      definitions = list(list(
        name = "dynamic_round",
        expr = "ROUND(number, number)"
      ))
    ))
  )
  definitions <- definition_compiled_table(definition_compile_source(
    raw,
    data_source(values = data.frame(number = 1))
  ))

  expect_null(
    definition_translation(definitions$dynamic_round, "SQL(snowflake)")$error
  )
  expect_match(
    definition_translation(
      definitions$dynamic_round,
      "SQL(databricks)"
    )$error,
    "dynamic ROUND"
  )

  constant <- list(
    tables = list(list(
      name = "values",
      columns = list(list(name = "number", type = "number(quantity)")),
      definitions = list(list(
        name = "fractional_scale",
        expr = "ROUND(number, 1.5)"
      ))
    ))
  )
  definitions <- definition_compiled_table(definition_compile_source(
    constant,
    data_source(values = data.frame(number = 1))
  ))
  expect_equal(
    definition_translation(
      definitions$fractional_scale,
      "SQL(snowflake)"
    )$code,
    'round("number", TRUNC(1.5))'
  )
  expect_equal(
    definition_translation(
      definitions$fractional_scale,
      "SQL(databricks)"
    )$code,
    "round(`number`, CAST(1.5 AS INT))"
  )

  nanosecond <- list(
    tables = list(list(
      name = "values",
      columns = list(list(name = "observed", type = "datetime")),
      definitions = list(list(
        name = "after_threshold",
        expr = "observed > '2024-01-01T00:00:00.123456789Z'"
      ))
    ))
  )
  definitions <- definition_compiled_table(definition_compile_source(
    nanosecond,
    data_source(values = data.frame(observed = Sys.time()))
  ))
  expect_match(
    definition_translation(
      definitions$after_threshold,
      "SQL(databricks)"
    )$error,
    "microsecond precision"
  )
})

test_that("composition carries dependency fidelity notes", {
  local_mocked_bindings(
    is_snowflake_connection = function(con) TRUE,
    is_databricks_connection = function(con) FALSE
  )
  raw <- list(
    tables = list(list(
      name = "values",
      columns = list(list(name = "number", type = "number(quantity)")),
      definitions = list(
        list(name = "positive", expr = "number > 0"),
        list(name = "any_positive", expr = "ANY(positive)")
      )
    ))
  )
  definitions <- definition_compiled_table(definition_compile_source(
    raw,
    definition_mock_source("values")
  ))

  expect_match(
    definitions$any_positive$notes,
    "IEEE comparisons",
    fixed = TRUE
  )
})

test_that("composition replaces identifiers but leaves literals intact", {
  snowflake <- definition_compose_identifiers(
    '"a""b" OR "other" = \'a"b\'',
    stats::setNames("TRUE", 'a"b'),
    "SQL(snowflake)"
  )
  databricks <- definition_compose_identifiers(
    "`a``b` OR `other` = 'a`b'",
    stats::setNames("TRUE", "a`b"),
    "SQL(databricks)"
  )

  expect_equal(snowflake, '(TRUE) OR "other" = \'a"b\'')
  expect_equal(databricks, "(TRUE) OR `other` = 'a`b'")
})

test_that("physical columns cannot be confused with sibling definitions", {
  local_mocked_bindings(
    is_snowflake_connection = function(con) TRUE,
    is_databricks_connection = function(con) FALSE
  )
  raw <- list(
    tables = list(list(
      name = "values",
      columns = list(list(name = "amount", type = "number(quantity)")),
      definitions = list(
        list(name = "AMOUNT", expr = "1"),
        list(name = "combined", expr = "amount + AMOUNT")
      )
    ))
  )
  bindings <- list(
    tables = c(values = "ANALYTICS.PUBLIC.VALUES"),
    columns = list(values = c(amount = "AMOUNT")),
    strict = TRUE
  )
  compiled <- definition_compile_source(
    raw,
    definition_mock_source("ANALYTICS.PUBLIC.VALUES", bindings)
  )

  expect_equal(
    definition_compiled_table(compiled)$combined$sql,
    '"AMOUNT" + (1)'
  )
})

test_that("target string literals preserve backslashes", {
  expect_equal(definition_sql_string("a\\b", "snowflake"), "'a\\\\b'")
  expect_equal(definition_sql_string("a\\b", "databricks"), "'a\\\\b'")
})

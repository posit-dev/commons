test_that("landed definition envelopes export inferred records", {
  skip_if_not_installed("yaml")
  path <- test_path("fixtures", "definition-export", "valid", "core.yaml")
  export <- definition_export_spec(yaml::read_yaml(path))
  definitions <- export$tables$orders$definitions

  expect_equal(
    vapply(definitions, `[[`, character(1), "kind"),
    c("metric", "filter", "metric", "derived")
  )
  expect_equal(
    vapply(definitions, `[[`, character(1), "type"),
    c("number", "boolean", "number", "number")
  )
  expect_equal(definitions[[3]]$columns, "order_total")
  expect_equal(definitions[[3]]$definitions, "is_enterprise")
  expect_equal(
    definitions[[3]]$translations[[1]]$code,
    'sum(CASE WHEN "is_enterprise" THEN "order_total" ELSE 0 END)'
  )
})

test_that("the expression parser preserves data-dict precedence", {
  expression <- definition_expr_parse(
    "NOT flag OR amount + 1 * 2 >= 10 AND text LIKE 'A%'"
  )

  expect_identical(expression$kind, "or")
  expect_identical(expression$lhs$kind, "not")
  expect_identical(expression$rhs$kind, "and")
  expect_identical(expression$rhs$lhs$kind, "compare")
  expect_identical(expression$rhs$lhs$lhs$kind, "arithmetic")
  expect_identical(expression$rhs$lhs$lhs$rhs$kind, "arithmetic")
  expect_identical(expression$rhs$rhs$kind, "like")
})

test_that("quoted definition names and struct fields resolve separately", {
  skip_if_not_installed("yaml")
  path <- test_path("fixtures", "definition-export", "valid", "language.yaml")
  definitions <- definition_export_spec(yaml::read_yaml(
    path
  ))$tables$survey$definitions
  names <- vapply(definitions, `[[`, character(1), "name")
  postal <- definitions[[match("postal length", names)]]
  long <- definitions[[match("long postal", names)]]

  expect_equal(postal$columns, "profile.zip")
  expect_length(postal$definitions, 0L)
  expect_equal(long$definitions, "postal length")
  expect_length(long$columns, 0L)
  expect_equal(long$translations[[1]]$code, '"postal length" > 5')
})

test_that("COLUMNS selections expand in DuckDB translations", {
  skip_if_not_installed("yaml")
  path <- test_path("fixtures", "definition-export", "valid", "language.yaml")
  definitions <- definition_export_spec(yaml::read_yaml(
    path
  ))$tables$survey$definitions
  names <- vapply(definitions, `[[`, character(1), "name")
  complete <- definitions[[match("complete", names)]]
  missing <- definitions[[match("anything missing", names)]]

  expect_equal(complete$columns, c("q1", "q2"))
  expect_equal(
    complete$translations[[1]]$code,
    '"q1" IS NOT NULL AND "q2" IS NOT NULL'
  )
  expect_false("untyped" %in% missing$columns)
  expect_match(missing$translations[[1]]$code, '"untyped"', fixed = TRUE)
})

test_that("DuckDB mappings carry data-dict fidelity notes", {
  skip_if_not_installed("yaml")
  path <- test_path("fixtures", "definition-export", "valid", "functions.yaml")
  definitions <- definition_export_spec(yaml::read_yaml(
    path
  ))$tables$values$definitions
  names <- vapply(definitions, `[[`, character(1), "name")
  remainder <- definitions[[match("remainder", names)]]
  folds <- definitions[[match("folds", names)]]

  expect_equal(
    remainder$translations[[1]]$code,
    'mod(mod("number", 3) + 3, 3)'
  )
  expect_match(
    remainder$translations[[1]]$notes,
    "integer modulus by zero",
    fixed = TRUE
  )
  expect_match(
    folds$translations[[1]]$notes,
    "sums integers at 128 bits",
    fixed = TRUE
  )
})

test_that("DuckDB literals use data-dict's canonical forms", {
  skip_if_not_installed("yaml")
  path <- test_path("fixtures", "definition-export", "valid", "language.yaml")
  definitions <- definition_export_spec(yaml::read_yaml(
    path
  ))$tables$survey$definitions
  definitions <- setNames(
    definitions,
    vapply(definitions, `[[`, character(1), "name")
  )

  expect_equal(
    definitions[["exact match"]]$translations[[1]]$code,
    '"pattern" = \'a\''
  )
  expect_equal(
    definitions[["fractional time"]]$translations[[1]]$code,
    '"observed" <= TIMESTAMP \'2024-01-01 01:30:00.123\''
  )
  expect_equal(
    definitions[["precise threshold"]]$translations[[1]]$code,
    '"amount" > 0.12345678901234566'
  )
  expect_equal(
    definitions[["selected dates"]]$translations[[1]]$code,
    '"created" >= \'2020-01-01\''
  )
})

test_that("valid definition fixtures pass the local exporter", {
  skip_if_not_installed("yaml")
  for (path in definition_fixture_paths("valid")) {
    expect_no_error(definition_export_spec(yaml::read_yaml(path)))
  }
})

test_that("invalid definition fixtures fail the local exporter", {
  skip_if_not_installed("yaml")
  for (path in definition_fixture_paths("invalid")) {
    expect_error(
      definition_export_spec(yaml::read_yaml(path)),
      info = basename(path)
    )
  }
})

test_that("the local export agrees with an installed data-dict", {
  skip_if_not_installed("yaml")
  for (path in definition_fixture_paths("valid")) {
    validation <- data_dict_cli_run(c("validate-spec", path, "--json"))
    expect_identical(
      validation$status,
      0L,
      info = data_dict_cli_context(validation)
    )
    exported <- data_dict_cli_run(c("export-spec", path))
    expect_identical(
      exported$status,
      0L,
      info = data_dict_cli_context(exported)
    )
    upstream <- jsonlite::fromJSON(exported$stdout, simplifyVector = FALSE)
    local <- definition_export_spec(yaml::read_yaml(path))
    expect_equal(
      definition_export_contract(local),
      definition_export_contract(upstream),
      info = paste(basename(path), data_dict_cli_context(exported))
    )
  }
})

test_that("invalid fixtures also fail an installed data-dict", {
  for (path in definition_fixture_paths("invalid")) {
    validation <- data_dict_cli_run(c("validate-spec", path, "--json"))
    expect_false(
      identical(validation$status, 0L),
      info = paste(basename(path), data_dict_cli_context(validation))
    )
    report <- jsonlite::fromJSON(validation$stdout, simplifyVector = FALSE)
    codes <- vapply(report$problems, `[[`, character(1), "code")
    expect_contains(codes, definition_fixture_error_code(path))
  }
})

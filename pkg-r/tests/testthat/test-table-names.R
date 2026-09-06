# Table-name parsing, driven by the shared fixture.
#
# How a `tables` string splits into catalog, schema, and table is a
# cross-language contract, so the cases live in tests/shared/table-names.json
# and the Python suite runs the same ones. Do not restate a case here; add it
# to the fixture.

# The fixture pins the refusal as a slug; the wording belongs to each
# language.
table_name_error_patterns <- list(
  too_many_parts = "at most three parts",
  empty_component = "empty name components",
  not_a_name = "must be a table name"
)

test_that("the shared fixture covers every shape", {
  cases <- shared_fixture("table-names")$parse_table_name$cases
  # A truncated fixture would silently collect zero cases and the suite
  # would still pass, so pin the coverage the table must have.
  expect_gt(length(cases), 0)

  successes <- Filter(function(case) is.null(case$error), cases)
  expect_setequal(
    vapply(successes, function(case) length(case$expected), integer(1)),
    c(1L, 2L, 3L)
  )
  errors <- Filter(function(case) !is.null(case$error), cases)
  expect_setequal(
    vapply(errors, function(case) case$error, character(1)),
    names(table_name_error_patterns)
  )
})

test_that("table_entry_id matches the shared fixture", {
  cases <- shared_fixture("table-names")$parse_table_name$cases

  for (case in cases) {
    if (!is.null(case$error)) {
      expect_error(
        table_entry_id(case$input),
        regexp = table_name_error_patterns[[case$error]],
        fixed = TRUE
      )
      next
    }

    id <- table_entry_id(case$input)
    expect_identical(as.list(id@name), case$expected, info = case$name)
    # The label is what the agent sees, so it round-trips the input.
    expect_identical(table_id_label(id), case$input, info = case$name)
  }
})

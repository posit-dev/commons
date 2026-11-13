# The typed-parameter contract both packages consume. The Python suite runs
# the same cases from the same file. See tests/shared/README.md.

typed_parameter_cases <- function(section) {
  cases <- shared_fixture("typed-parameters")[[section]]$cases
  # An empty section would enumerate no cases and the runner would pass.
  expect_gt(length(cases), 0)
  cases
}

test_that("declared types map to the parameter types in the shared fixture", {
  for (case in typed_parameter_cases("declared_types")) {
    expect_identical(
      semantic_parameter_type(case$declared),
      case$type,
      info = case$declared
    )
  }
})

test_that("parameter values are accepted as the shared fixture says", {
  for (case in typed_parameter_cases("values")) {
    specification <- new_typed_argument("x", case$type)
    label <- paste(case$type, deparse(case$value))
    result <- tryCatch(
      validate_typed_value(case$value, specification),
      error = function(err) err
    )
    if (isTRUE(case$valid)) {
      expect_false(inherits(result, "error"), info = label)
      next
    }
    expect_s3_class(result, "error")
    reason <- if (grepl("non-missing", conditionMessage(result))) "missing" else "type"
    expect_identical(reason, case$error, info = label)
  }
})

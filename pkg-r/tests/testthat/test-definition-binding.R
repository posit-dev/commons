# The definition-binding contract in tests/shared/, run against the R
# implementation. The Python suite runs the same cases from the same file.

binding_error_class <- c(
  absent_column = "commons_definition_absent_column_error",
  unmatched_table = "commons_definition_unmatched_table_error"
)

compile_binding_case <- function(case) {
  local_mocked_bindings(
    is_snowflake_connection = function(con) identical(case$backend, "snowflake"),
    is_databricks_connection = function(con) identical(case$backend, "databricks")
  )
  merged <- merge_shared_case(case)
  source <- new_data_source(
    structure(list(), class = "mock_connection"),
    tables = names(merged$dictionary$tables),
    owned = FALSE,
    definition_bindings = merged$definition_bindings
  )
  compiled <- definition_compile_source(case$dictionary, source)
  lapply(compiled$tables, function(table) {
    sql <- lapply(table$definitions, `[[`, "sql")
    names(sql) <- vapply(table$definitions, `[[`, character(1), "name")
    sql
  })
}

test_that("definition binding matches the shared contract", {
  cases <- shared_fixture("definition-binding")$cases
  expect_gt(length(cases), 0L)
  for (case in cases) {
    if (!is.null(case$expect$error)) {
      expect_error(
        compile_binding_case(case),
        class = binding_error_class[[case$expect$error]]
      )
      next
    }
    expect_identical(
      compile_binding_case(case),
      case$expect$tables,
      label = case$name
    )
  }
})

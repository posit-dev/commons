# The catalog-merge contract in tests/shared/, run against the R
# implementation. The Python suite runs the same cases from the same file.

as_binding <- function(x) {
  # A bindings entry as a named character vector, with JSON nulls as NA and
  # an empty entry as a plain empty vector either side can produce.
  if (is.null(x) || length(x) == 0L) {
    return(character(0))
  }
  vapply(x, function(value) value %||% NA_character_, character(1))
}

test_that("catalog limits match the shared contract", {
  limits <- shared_fixture("catalog-merge")$limits
  expect_equal(catalog_object_limit, limits$object)
  expect_equal(catalog_prompt_limit, limits$prompt)
  expect_equal(catalog_search_probe_limit, limits$search_probe)
})

test_that("exclusion globs match the shared contract", {
  cases <- shared_fixture("catalog-merge")$exclusion
  expect_gt(length(cases), 0L)
  for (case in cases) {
    patterns <- unlist(case$patterns)
    hidden <- catalog_excluded(
      unlist(case$names),
      if (length(patterns)) patterns else NULL
    )
    expect_identical(unname(hidden), unlist(case$hidden))
  }
})

test_that("the dictionary merge matches the shared contract", {
  cases <- shared_fixture("catalog-merge")$merge
  expect_gt(length(cases), 0L)
  for (case in cases) {
    dictionary <- new_data_dictionary(case$dictionary)
    relations <- list()
    columns <- list()
    for (entry in case$relations) {
      id_args <- Filter(Negate(is.null), entry[c("catalog", "schema", "table")])
      relations[[entry$label]] <- list(
        id = do.call(DBI::Id, id_args),
        kind = entry$kind,
        description = entry$description
      )
      columns[[entry$label]] <- entry$columns
    }
    describe <- function(con, id, ...) {
      rows <- columns[[table_id_label(id)]]
      data.frame(
        column = vapply(rows, `[[`, character(1), "column"),
        type = vapply(rows, function(row) row$type %||% NA_character_, character(1)),
        nullable = vapply(rows, function(row) row$nullable %||% NA, logical(1)),
        description = vapply(
          rows,
          function(row) row$description %||% NA_character_,
          character(1)
        ),
        stringsAsFactors = FALSE
      )
    }
    run <- function() {
      catalog_merge_dictionary(
        dictionary,
        relations,
        NULL,
        describe,
        case$identifier_case
      )
    }
    if (!is.null(case$expect$error)) {
      expect_error(run())
      next
    }
    merged <- run()
    expected <- case$expect$tables
    expect_identical(names(merged$dictionary$tables), names(expected))
    for (label in names(expected)) {
      want <- expected[[label]]
      table <- merged$dictionary$tables[[label]]
      expect_identical(table$.authored_name, want$authored_name)
      expect_identical(table$kind, want$kind)
      expect_identical(table$description, want$description)
      expect_identical(
        names(table$columns) %||% character(0),
        vapply(want$columns, `[[`, character(1), "name")
      )
      for (want_column in want$columns) {
        column <- table$columns[[want_column$name]]
        expect_identical(column$type, want_column$type)
        expect_identical(column$nullable, want_column$nullable)
        expect_identical(column$description, want_column$description)
      }
    }
    expect_equal(
      as_binding(merged$definition_bindings$tables),
      as_binding(case$expect$bindings$tables)
    )
    got_columns <- merged$definition_bindings$columns
    want_columns <- case$expect$bindings$columns
    expect_identical(names(got_columns), names(want_columns))
    for (authored in names(want_columns)) {
      expect_equal(
        as_binding(got_columns[[authored]]),
        as_binding(want_columns[[authored]])
      )
    }
  }
})

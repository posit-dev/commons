# Shared with the Python suite: which rows are relations, what kind each is,
# which comments count as prose, and where a DESCRIBE reply stops being
# columns. Pinned in tests/shared/catalog-rows.json rather than asserted in
# each language.
catalog_rows_frame <- function(rows) {
  columns <- unique(unlist(lapply(rows, names), use.names = FALSE))
  frame <- lapply(columns, function(column) {
    vapply(
      rows,
      function(row) {
        value <- row[[column]]
        if (is.null(value)) NA_character_ else as.character(value)
      },
      character(1)
    )
  })
  names(frame) <- columns
  as.data.frame(frame, stringsAsFactors = FALSE, check.names = FALSE)
}

catalog_rows_expect_relations <- function(relations, expected, info) {
  expect_length(relations, length(expected))
  for (i in seq_along(expected)) {
    case <- expected[[i]]
    expect_identical(
      relations[[i]]$id,
      DBI::Id(
        catalog = case$catalog,
        schema = case$schema,
        table = case$table
      ),
      info = info
    )
    expect_equal(relations[[i]]$kind, case$kind, info = info)
    if (nzchar(case$description)) {
      expect_equal(relations[[i]]$description, case$description, info = info)
    } else {
      expect_null(relations[[i]]$description, info = info)
    }
  }
}

catalog_rows_expect_columns <- function(columns, expected, info) {
  expect_equal(nrow(columns), length(expected), info = info)
  for (i in seq_along(expected)) {
    case <- expected[[i]]
    expect_equal(columns$column[[i]], case$column, info = info)
    expect_equal(columns$type[[i]], case$type, info = info)
    expect_equal(columns$nullable[[i]], case$nullable == "true", info = info)
    if (nzchar(case$description)) {
      expect_equal(columns$description[[i]], case$description, info = info)
    } else {
      expect_true(is.na(columns$description[[i]]), info = info)
    }
  }
}

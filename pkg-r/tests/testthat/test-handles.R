test_that("both packages hand out the same handles", {
  section <- shared_fixture("handles")$registrations
  expect_gt(length(section$cases), 0)

  for (case in section$cases) {
    store <- new_handle_store()

    for (index in seq_along(case$values)) {
      spec <- case$values[[index]]
      expected <- case$expected[[index]]
      value <- switch(
        spec$kind,
        nothing = NULL,
        scalar = 6L,
        data.frame(n = seq_len(spec$rows))
      )

      note <- register_handle(store, value, max_rows = section$max_rows)

      if (is.null(expected$handle)) {
        expect_null(note, info = case$name)
        next
      }
      opening <- section$note_template
      opening <- gsub("{tool}", "run_r", opening, fixed = TRUE)
      opening <- gsub("{handle}", expected$handle, opening, fixed = TRUE)
      expected_first <- if (expected$truncated) {
        paste(opening, section$truncation_note)
      } else {
        opening
      }
      expect_identical(
        strsplit(note, "\n", fixed = TRUE)[[1]][[1]],
        expected_first,
        info = case$name
      )
      if (!is.null(expected$stored_rows)) {
        expect_identical(
          nrow(get_handle(store, expected$handle)),
          as.integer(expected$stored_rows),
          info = case$name
        )
      }
    }

    registered <- Filter(function(step) !is.null(step$handle), case$expected)
    expect_identical(
      handle_ids(store),
      vapply(registered, function(step) step$handle, character(1)),
      info = case$name
    )
  }
})

test_that("a missing store registers nothing, and an empty store has no ids", {
  expect_null(register_handle(NULL, 1))
  expect_identical(handle_ids(new_handle_store()), character())
})

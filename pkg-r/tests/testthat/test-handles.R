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
      expect_match(
        note,
        paste0("`", expected$handle, "`"),
        fixed = TRUE,
        info = case$name
      )
      expect_identical(
        grepl(section$truncation_note, note, fixed = TRUE),
        expected$truncated,
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

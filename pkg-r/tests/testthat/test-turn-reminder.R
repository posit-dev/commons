test_that("append_turn_reminder matches the shared fixture", {
  spec <- shared_fixture("turn-reminders")$claude_5_turn_reminder
  # An empty fixture would make the loop below vacuously succeed.
  expect_gt(length(spec$cases), 0)
  expect_identical(claude_5_turn_reminder, spec$text)

  for (case in spec$cases) {
    inputs <- append_turn_reminder(list("What was revenue?"), case$model)

    if (!isTRUE(case$appended)) {
      expect_identical(inputs, list("What was revenue?"), info = case$name)
      next
    }
    expect_length(inputs, 2)
    expect_true(
      S7::S7_inherits(inputs[[2]], ContentTurnReminder),
      info = case$name
    )
    expect_identical(inputs[[2]]@text, spec$text, info = case$name)
  }
})

test_that("the restored-conversation reminder renders the shared wording", {
  spec <- shared_fixture("turn-reminders")$restored_conversation_reminder
  values <- spec$substitutions$r
  expect_gt(length(values), 0)

  expected <- spec$template
  for (name in names(values)) {
    expected <- gsub(
      paste0("{", name, "}"),
      values[[name]],
      expected,
      fixed = TRUE
    )
  }

  expect_identical(restored_conversation_turn_reminder, expected)
  expect_identical(
    append_restored_conversation_reminder(list("What was revenue?"))[[2]]@text,
    expected
  )
})

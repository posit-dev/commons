test_that("split_exchanges opens at plain user turns only", {
  request <- ellmer::ContentToolRequest(
    id = "c1",
    name = "call_measure",
    arguments = list()
  )
  turns <- list(
    ellmer::SystemTurn("Be helpful."),
    ellmer::UserTurn(list(
      ellmer::ContentText("How many orders?"),
      ellmer::ContentText(brevity_turn_reminder)
    )),
    ellmer::AssistantTurn(list(request)),
    ellmer::UserTurn(list(ellmer::ContentToolResult(
      value = "ok",
      request = request
    ))),
    ellmer::AssistantTurn("6 orders."),
    ellmer::UserTurn("Thanks!")
  )

  expect_identical(split_exchanges(turns), list(turns[2:5], turns[6]))
})

test_that("current and legacy hidden follow-ups stay in their exchange", {
  for (tag in c("system-instruction", "reminder")) {
    instruction <- sprintf(
      "<%s>Fix the document.\n\n- Cell 1: boom</%s>",
      tag,
      tag
    )
    turns <- list(
      ellmer::UserTurn("Write a report."),
      ellmer::AssistantTurn("Here it is."),
      ellmer::UserTurn(list(ellmer::ContentText(instruction))),
      ellmer::AssistantTurn("Fixed it."),
      ellmer::UserTurn("Next question.")
    )

    expect_identical(split_exchanges(turns), list(turns[1:4], turns[5]))
  }
})

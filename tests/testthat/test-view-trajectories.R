# An exchange fragment: an assistant tool call and its tool-result turn,
# named like the tool the viewer derives trust levels from.
test_tool_turns <- function(name, id = "c1") {
  request <- ellmer::ContentToolRequest(id = id, name = name, arguments = list())
  list(
    ellmer::AssistantTurn(list(request)),
    ellmer::UserTurn(list(ellmer::ContentToolResult(value = "ok", request = request)))
  )
}

test_that("trajectory_provenance derives tags from tool calls and citations", {
  measure <- c(
    list(ellmer::UserTurn("How many orders?")),
    test_tool_turns("call_measure"),
    list(ellmer::AssistantTurn("6 orders."))
  )
  expect_equal(trajectory_provenance(measure)[[1]]$tag, "A")

  uncited <- c(
    list(ellmer::UserTurn("Total revenue?")),
    test_tool_turns("run_sql"),
    list(ellmer::AssistantTurn("5650."))
  )
  expect_equal(trajectory_provenance(uncited)[[1]]$tag, "C")

  # Citation *presence* makes a fallback answer "B": with no agent there is
  # no corpus, so even an unverifiable quote counts.
  cited <- c(
    list(ellmer::UserTurn("Total revenue?")),
    test_tool_turns("run_sql"),
    list(ellmer::AssistantTurn(
      "5650.\n\n<citation reason=\"definition\">Revenue excludes tax.</citation>"
    ))
  )
  expect_equal(trajectory_provenance(cited)[[1]]$tag, "B")

  mixed <- c(
    list(ellmer::UserTurn("Total revenue?")),
    test_tool_turns("call_measure", id = "c1"),
    test_tool_turns("run_sql", id = "c2"),
    list(ellmer::AssistantTurn("5650. <citation>Revenue excludes tax.</citation>"))
  )
  expect_equal(trajectory_provenance(mixed)[[1]]$tag, "B")

  untagged <- c(
    list(ellmer::UserTurn("What does revenue mean?")),
    test_tool_turns("search_context"),
    list(ellmer::AssistantTurn("Revenue excludes tax."))
  )
  expect_true(is.na(trajectory_provenance(untagged)[[1]]$tag))
})

test_that("tool names survive the OTLP round trip and drive derivation", {
  input <- paste0(
    '[{"role":"user","parts":[{"type":"text","content":"Total revenue?"}]},',
    '{"role":"assistant","parts":[{"type":"tool_call","id":"c1",',
    '"name":"run_sql","arguments":{"sql":"select 1"}}]},',
    '{"role":"tool","parts":[{"type":"tool_call_response","id":"c1",',
    '"response":"5650"}]}]'
  )
  output <- paste0(
    '[{"role":"assistant","parts":[{"type":"text",',
    '"content":"5650.\\n\\n<citation>Revenue excludes tax.</citation>"}]}]'
  )
  spans <- parse_otlp_lines(otlp_test_line(list(
    chat_test_span("t1", "s1", input_messages = input, output_messages = output)
  )))

  turns <- build_trajectories(spans)[[1]]
  provenance <- trajectory_provenance(turns)

  expect_length(provenance, 1)
  expect_equal(provenance[[1]]$tag, "B")
})

test_that("split_exchanges opens at plain user turns only", {
  turns <- c(
    list(
      ellmer::SystemTurn("Be helpful."),
      ellmer::UserTurn("How many orders?")
    ),
    test_tool_turns("call_measure"),
    list(
      ellmer::AssistantTurn("6 orders."),
      ellmer::UserTurn("Thanks!")
    )
  )

  exchanges <- split_exchanges(turns)

  expect_length(exchanges, 2)
  # The system turn belongs to no exchange; the tool-result UserTurn stays
  # inside its exchange rather than opening one.
  expect_length(exchanges[[1]], 4)
  expect_equal(exchanges[[1]][[1]]@text, "How many orders?")
  expect_length(exchanges[[2]], 1)
})

test_that("summarize_trajectories describes each conversation", {
  active <- c(
    list(ellmer::UserTurn("How   many\norders came in  last week?")),
    test_tool_turns("call_measure"),
    list(
      ellmer::AssistantTurn("6 orders."),
      ellmer::UserTurn("Total revenue?")
    ),
    test_tool_turns("run_sql", id = "c2"),
    list(ellmer::AssistantTurn("5650."))
  )
  attr(active, "last_active") <- as.POSIXct("2026-07-22 14:30:00")
  trajectories <- list(
    conv1 = active,
    conv2 = list(
      ellmer::UserTurn("What does revenue mean?"),
      ellmer::AssistantTurn("Revenue excludes tax.")
    )
  )

  summary <- summarize_trajectories(trajectories)

  expect_length(summary, 2)
  expect_equal(summary[[1]]$id, "conv1")
  expect_equal(summary[[1]]$snippet, "How many orders came in last week?")
  expect_equal(summary[[1]]$n_user_turns, 2)
  expect_equal(summary[[1]]$tags, c("A", "C"))
  expect_equal(summary[[1]]$last_active, as.POSIXct("2026-07-22 14:30:00"))
  expect_equal(summary[[2]]$tags, NA_character_)
  expect_true(is.na(summary[[2]]$last_active))
})

test_that("hit_rate counts exchange tags across conversations", {
  rate <- hit_rate(list(c("A", "C"), "B", NA_character_))

  expect_equal(rate$n, 4)
  expect_equal(rate$counts, c(A = 1, B = 1, C = 1, none = 1))
})

test_that("trajectory_transcript merges each exchange into chat messages", {
  skip_if_not_installed("shinychat")
  skip_if_not_installed("htmltools")

  turns <- c(
    list(ellmer::UserTurn("How many orders?")),
    test_tool_turns("call_measure"),
    list(
      ellmer::AssistantTurn("6 orders."),
      ellmer::UserTurn("Total revenue?")
    ),
    test_tool_turns("run_sql", id = "c2"),
    list(ellmer::AssistantTurn(
      "5650.\n\n<citation>Revenue excludes tax.</citation>"
    ))
  )

  transcript <- trajectory_transcript(turns)

  expect_equal(
    vapply(transcript$messages, function(m) m$role, character(1)),
    c("user", "assistant", "user", "assistant")
  )
  expect_equal(transcript$count, 2)

  answer <- transcript$messages[[2]]$content
  expect_length(answer, 2)
  expect_s3_class(answer[[1]], "shinychat_tool_card")
  expect_equal(answer[[2]], "6 orders.")

  # The verified-answer pill lands on the first answer; the cited answer
  # sends an empty pill whose unverified citations still trigger markup
  # cleanup client-side.
  expect_length(transcript$pills, 2)
  expect_match(transcript$pills[[1]]$html, "commons-answer-pill-trusted")
  expect_equal(transcript$pills[[1]]$indexFromEnd, 1)
  expect_equal(as.character(transcript$pills[[2]]$html), "")
  expect_equal(transcript$pills[[2]]$citations, list(list(verified = FALSE)))
  expect_equal(transcript$pills[[2]]$indexFromEnd, 0)
})

test_that("trajectory_transcript keeps unanswered questions out of the count", {
  skip_if_not_installed("shinychat")
  skip_if_not_installed("htmltools")

  turns <- c(
    list(ellmer::UserTurn("How many orders?")),
    test_tool_turns("call_measure"),
    list(
      ellmer::AssistantTurn("6 orders."),
      ellmer::UserTurn("Total revenue?")
    )
  )

  transcript <- trajectory_transcript(turns)

  expect_equal(
    vapply(transcript$messages, function(m) m$role, character(1)),
    c("user", "assistant", "user")
  )
  expect_equal(transcript$count, 1)
  expect_length(transcript$pills, 1)
  expect_equal(transcript$pills[[1]]$indexFromEnd, 0)
})

test_that("check_trajectories accepts empty trajectories and rejects other shapes", {
  expect_no_error(check_trajectories(list()))
  expect_snapshot(check_trajectories("nope"), error = TRUE)
  expect_snapshot(check_trajectories(list(list())), error = TRUE)
})

test_that("the viewer filters conversations and follows selection", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("shinychat")
  skip_if_not_installed("htmltools")

  early <- list(ellmer::UserTurn("One."), ellmer::AssistantTurn("1."))
  attr(early, "last_active") <- as.POSIXct("2026-07-01 09:00:00")
  late <- list(ellmer::UserTurn("Two."), ellmer::AssistantTurn("2."))
  attr(late, "last_active") <- as.POSIXct("2026-07-20 09:00:00")
  trajectories <- list(conv1 = early, conv2 = late)
  summary <- summarize_trajectories(trajectories)

  shiny::testServer(viewer_server(trajectories, summary), {
    session$setInputs(window = c(as.Date("2026-07-01"), as.Date("2026-07-31")))
    expect_equal(visible(), c(1, 2))

    session$setInputs(window = c(as.Date("2026-07-15"), as.Date("2026-07-31")))
    expect_equal(visible(), 2)

    expect_null(selected())
    session$setInputs(conversation_2 = 1)
    expect_equal(selected(), 2)
  })
})

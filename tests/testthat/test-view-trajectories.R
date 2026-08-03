# An exchange fragment: an assistant tool call and its tool-result turn,
# named like the tool the viewer derives trust levels from.
test_tool_turns <- function(name, id = "c1") {
  request <- ellmer::ContentToolRequest(
    id = id,
    name = name,
    arguments = list()
  )
  list(
    ellmer::AssistantTurn(list(request)),
    ellmer::UserTurn(list(ellmer::ContentToolResult(
      value = "ok",
      request = request
    )))
  )
}

test_that("exchange_provenance derives tags from tool calls and citations", {
  measure <- c(
    list(ellmer::UserTurn("How many orders?")),
    test_tool_turns("call_measure"),
    list(ellmer::AssistantTurn("6 orders."))
  )
  expect_equal(exchange_provenance(measure)$tag, "A")

  uncited <- c(
    list(ellmer::UserTurn("Total revenue?")),
    test_tool_turns("run_sql"),
    list(ellmer::AssistantTurn("5650."))
  )
  expect_equal(exchange_provenance(uncited)$tag, "C")

  # Citation *presence* makes a fallback answer "B": with no agent there is
  # no corpus, so even an unverifiable quote counts.
  cited <- c(
    list(ellmer::UserTurn("Total revenue?")),
    test_tool_turns("run_sql"),
    list(ellmer::AssistantTurn(
      "5650.\n\n<citation reason=\"definition\">Revenue excludes tax.</citation>"
    ))
  )
  expect_equal(exchange_provenance(cited)$tag, "B")

  mixed <- c(
    list(ellmer::UserTurn("Total revenue?")),
    test_tool_turns("call_measure", id = "c1"),
    test_tool_turns("run_sql", id = "c2"),
    list(ellmer::AssistantTurn(
      "5650. <citation>Revenue excludes tax.</citation>"
    ))
  )
  expect_equal(exchange_provenance(mixed)$tag, "B")

  untagged <- c(
    list(ellmer::UserTurn("What does revenue mean?")),
    test_tool_turns("search_context"),
    list(ellmer::AssistantTurn("Revenue excludes tax."))
  )
  expect_true(is.na(exchange_provenance(untagged)$tag))
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
  provenance <- lapply(split_exchanges(turns), exchange_provenance)

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
  expect_equal(
    vapply(transcript$messages, function(m) m$exchange, integer(1)),
    c(1L, 1L, 2L, 2L)
  )
  expect_equal(transcript$count, 2)

  answer <- transcript$messages[[2]]$content
  expect_length(answer, 2)
  expect_s3_class(answer[[1]], "shinychat_tool_card")
  expect_equal(answer[[2]], "6 orders.")

  # The verified-answer pill lands on the first answer; the cited answer
  # sends an empty pill whose citations become unverified-but-visible
  # footnotes.
  expect_length(transcript$pills, 2)
  expect_match(transcript$pills[[1]]$html, "commons-answer-pill-trusted")
  expect_equal(transcript$pills[[1]]$indexFromEnd, 1)
  expect_equal(as.character(transcript$pills[[2]]$html), "")
  expect_equal(
    transcript$pills[[2]]$citations,
    list(list(
      verified = TRUE,
      reason = NULL,
      quote = "Revenue excludes tax.",
      label = "unverified"
    ))
  )
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

test_that("side calls are excluded from the viewer", {
  title_call <- list(
    ellmer::SystemTurn(
      "You title chat conversations. Reply with ONLY a title."
    ),
    ellmer::UserTurn("user: How many orders? assistant: 6 orders.")
  )
  promptless <- list(
    ellmer::SystemTurn("Be helpful."),
    ellmer::AssistantTurn("An unprompted completion.")
  )
  real <- list(
    ellmer::SystemTurn("Be helpful."),
    ellmer::UserTurn("How many orders?"),
    ellmer::AssistantTurn("6 orders.")
  )

  expect_true(is_side_conversation(title_call))
  expect_true(is_side_conversation(promptless))
  expect_false(is_side_conversation(real))

  trajectories <- list(t = title_call, p = promptless, r = real)
  expect_message(
    kept <- drop_side_conversations(trajectories),
    "Excluding 2 logged calls"
  )
  expect_named(kept, "r")
})

test_that("summarize_questions flattens exchanges across conversations", {
  first <- c(
    list(ellmer::UserTurn("How many orders?")),
    test_tool_turns("call_measure"),
    list(
      ellmer::AssistantTurn("6 orders."),
      ellmer::UserTurn("Total revenue?")
    ),
    test_tool_turns("run_sql", id = "c2"),
    list(ellmer::AssistantTurn("5650."))
  )
  attr(first, "last_active") <- as.POSIXct("2026-07-22 14:30:00")
  trajectories <- list(
    conv1 = first,
    conv2 = list(ellmer::UserTurn("What does revenue mean?"))
  )

  questions <- summarize_questions(trajectories)

  expect_length(questions, 3)
  expect_equal(questions[[2]]$conversation, 1)
  expect_equal(questions[[2]]$exchange, 2)
  expect_equal(questions[[2]]$snippet, "Total revenue?")
  expect_equal(questions[[2]]$tag, "C")
  expect_equal(questions[[2]]$last_active, as.POSIXct("2026-07-22 14:30:00"))
  expect_true(is.na(questions[[3]]$tag))
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

  early <- c(
    list(ellmer::UserTurn("One?")),
    test_tool_turns("call_measure"),
    list(ellmer::AssistantTurn("1."))
  )
  attr(early, "last_active") <- as.POSIXct("2026-07-01 09:00:00")
  late <- c(
    list(ellmer::UserTurn("Two?")),
    test_tool_turns("run_sql"),
    list(ellmer::AssistantTurn("2."))
  )
  attr(late, "last_active") <- as.POSIXct("2026-07-20 09:00:00")
  trajectories <- list(conv1 = early, conv2 = late)
  summary <- summarize_trajectories(trajectories)
  questions <- summarize_questions(trajectories)
  review_file <- withr::local_tempfile(fileext = ".jsonl")

  shiny::testServer(
    viewer_server(trajectories, summary, questions, review_file),
    {
      session$setInputs(
        group_by = "conversation",
        trust = "all",
        window = c(as.Date("2026-07-01"), as.Date("2026-07-31"))
      )
      expect_equal(visible_conversations(), c(1, 2))
      expect_equal(visible_questions(), c(1, 2))

      session$setInputs(
        window = c(as.Date("2026-07-15"), as.Date("2026-07-31"))
      )
      expect_equal(visible_conversations(), 2)

      session$setInputs(
        window = c(as.Date("2026-07-01"), as.Date("2026-07-31")),
        trust = "C"
      )
      expect_equal(visible_conversations(), 2)
      expect_equal(visible_questions(), 2)

      expect_null(selected())
      session$setInputs(entry_2_1 = 1)
      expect_equal(selected(), list(conversation = 2, exchange = 1))
      expect_equal(review_target(), selected())
      session$setInputs(entry_1 = 1)
      expect_equal(selected(), list(conversation = 1))
      expect_null(review_target())
      session$setInputs(exchange_select = list(exchange = 1, nonce = 1))
      expect_equal(review_target(), list(conversation = 1, exchange = 1L))

      # Clicking the selected exchange again deselects it.
      session$setInputs(exchange_select = list(nonce = 2))
      expect_null(review_target())

      # Moving to another entry drops the previous exchange selection.
      session$setInputs(exchange_select = list(exchange = 1, nonce = 3))
      expect_equal(review_target(), list(conversation = 1, exchange = 1L))
      session$setInputs(entry_2 = 1)
      expect_null(review_target())
    }
  )
})

test_that("flags and notes append to and restore from the review file", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("shinychat")
  skip_if_not_installed("htmltools")

  turns <- list(ellmer::UserTurn("One?"), ellmer::AssistantTurn("1."))
  trajectories <- list(conv1 = turns)
  summary <- summarize_trajectories(trajectories)
  questions <- summarize_questions(trajectories)
  review_file <- withr::local_tempfile(fileext = ".jsonl")

  shiny::testServer(
    viewer_server(trajectories, summary, questions, review_file),
    {
      session$setInputs(group_by = "conversation", trust = "all", entry_1 = 1)
      session$setInputs(flag_toggle = 1)
      expect_equal(flags(), "conv1")

      session$setInputs(exchange_select = list(exchange = 1, nonce = 1))
      session$setInputs(flag_toggle = 2)
      expect_equal(flags(), c("conv1", "conv1#1"))

      session$setInputs(review_note = "Wrong join, should use orders.")
      session$setInputs(save_note = 1)
      expect_length(notes(), 1)
      expect_equal(notes()[[1]]$note, "Wrong join, should use orders.")
      expect_equal(
        notes_for_selection(notes(), review_target(), summary),
        notes()
      )
    }
  )

  records <- lapply(readLines(review_file), jsonlite::fromJSON)
  expect_equal(
    vapply(records, function(r) r$action, character(1)),
    c("flag", "flag", "note")
  )
  expect_equal(records[[2]]$conversation, "conv1")
  expect_equal(records[[2]]$exchange, 1)
  expect_equal(records[[3]]$note, "Wrong join, should use orders.")

  restored <- read_review_records(review_file)
  expect_equal(review_flags(restored), c("conv1", "conv1#1"))
  expect_equal(
    vapply(review_notes(restored), `[[`, character(1), "note"),
    "Wrong join, should use orders."
  )
})

test_that("trust_timeline_days aggregates question tags by day", {
  questions <- list(
    list(tag = "A", last_active = as.POSIXct("2026-07-01 09:00:00")),
    list(tag = "C", last_active = as.POSIXct("2026-07-01 15:00:00")),
    list(tag = NA_character_, last_active = as.POSIXct("2026-07-03 10:00:00")),
    list(tag = "B", last_active = as.POSIXct(NA))
  )

  days <- trust_timeline_days(questions)

  # The undated question has no x position, so only two days chart.
  expect_length(days, 2)
  expect_equal(days[[1]]$date, "2026-07-01")
  expect_equal(days[[1]]$n, 2)
  expect_equal(days[[1]]$counts, list(A = 1L, B = 0L, C = 1L, none = 0L))
  expect_equal(days[[2]]$counts, list(A = 0L, B = 0L, C = 0L, none = 1L))

  windowed <- trust_timeline_days(
    questions,
    as.Date(c("2026-07-02", "2026-07-04"))
  )
  expect_length(windowed, 1)
  expect_equal(windowed[[1]]$date, "2026-07-03")
})

test_that("trust_timeline renders a chart and its table view", {
  skip_if_not_installed("htmltools")
  skip_if_not_installed("plotly")

  empty <- as.character(trust_timeline(list()))
  expect_match(empty, "No dated questions")

  days <- trust_timeline_days(list(
    list(tag = "A", last_active = as.POSIXct("2026-07-01 09:00:00")),
    list(tag = "A", last_active = as.POSIXct("2026-07-02 09:00:00")),
    list(tag = "C", last_active = as.POSIXct("2026-07-02 16:00:00"))
  ))

  # One stacked trace per trust level, sharing each day's answers out as
  # percentages.
  traces <- plotly::plotly_build(timeline_plot(days))$x$data
  expect_length(traces, length(viewer_levels))
  expect_equal(
    vapply(traces, function(trace) trace$name, character(1)),
    unname(viewer_levels)
  )
  expect_equal(as.numeric(traces[[1]]$y), c(100, 50))
  expect_equal(as.numeric(traces[[3]]$y), c(0, 50))

  # A single dated day charts as a stacked column instead of an area.
  single <- plotly::plotly_build(timeline_plot(days[1]))$x$data
  expect_equal(single[[1]]$type, "bar")

  html <- as.character(trust_timeline(days))
  # The table view carries every share the tooltip shows.
  expect_match(html, "commons-viewer-sr-only")
  expect_match(html, "50% (1)", fixed = TRUE)
})

test_that("the timeline legend carries each level's window-wide rate", {
  skip_if_not_installed("htmltools")

  legend <- as.character(timeline_legend(
    hit_rate(list(c("A", "C"), "B", NA_character_))
  ))

  expect_match(legend, "Verified")
  expect_match(legend, "<strong>25%</strong>", fixed = TRUE)
  expect_match(legend, "1 of 4 answers")

  empty <- as.character(timeline_legend(hit_rate(list())))
  expect_match(empty, "—")
})

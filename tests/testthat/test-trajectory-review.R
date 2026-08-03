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

test_that("reconstructed tool results wear the commons display again", {
  skip_if_not_installed("shinychat")
  skip_if_not_installed("htmltools")

  display <- viewer_tool_display(
    ellmer::ContentToolRequest(
      id = "c1",
      name = "run_sql",
      arguments = list(sql = "select 1")
    ),
    value = "| 1 |"
  )
  expect_equal(display$title, "Ran SQL")
  expect_false(display$show_request)
  expect_equal(display$markdown, "```sql\nselect 1\n```\n\n| 1 |")

  measure <- viewer_tool_display(ellmer::ContentToolRequest(
    id = "c2",
    name = "call_measure",
    arguments = list(name = "biodiversity_by_site", arguments = "{}")
  ))
  expect_equal(measure$title, "Measure: biodiversity by site")

  # Titles interpolate model-supplied arguments, so they are escaped.
  described <- viewer_tool_display(ellmer::ContentToolRequest(
    id = "c3",
    name = "describe_table",
    arguments = list(table = "<script>")
  ))
  expect_equal(described$title, "Described &lt;script&gt;")

  # Tools the viewer doesn't know keep shinychat's default card.
  expect_null(viewer_tool_display(ellmer::ContentToolRequest(
    id = "c4",
    name = "custom_tool",
    arguments = list()
  )))
  expect_null(viewer_tool_display(NULL))

  # The display lands on the transcript's cards, unless the result already
  # carries one.
  turns <- c(
    list(ellmer::UserTurn("Total revenue?")),
    test_tool_turns("run_sql"),
    list(ellmer::AssistantTurn("5650."))
  )
  card <- trajectory_transcript(turns)$messages[[2]]$content[[1]]
  expect_s3_class(card, "shinychat_tool_card")
  expect_match(format(card), "Ran SQL")
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

test_that("trajectory reviewer accepts empty trajectories and rejects other shapes", {
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

      # With the exchange deselected, notes cover the whole conversation.
      session$setInputs(exchange_select = list(nonce = 2))
      session$setInputs(review_note = "Reviewed end to end; looks fine.")
      session$setInputs(save_note = 2)
      expect_length(notes(), 2)
      expect_null(notes()[[2]]$exchange)
      expect_equal(
        notes_for_selection(notes(), list(conversation = 1), summary),
        notes()[2]
      )
    }
  )

  records <- lapply(readLines(review_file), jsonlite::fromJSON)
  expect_equal(
    vapply(records, function(r) r$action, character(1)),
    c("flag", "flag", "note", "note")
  )
  expect_equal(records[[2]]$conversation, "conv1")
  expect_equal(records[[2]]$exchange, 1)
  expect_equal(records[[3]]$note, "Wrong join, should use orders.")
  expect_null(records[[4]]$exchange)
  expect_equal(
    records[[2]][c("schema_version", "user", "source", "question", "tag")],
    list(
      schema_version = 1L,
      user = "unknown",
      source = list(kind = "unknown"),
      question = "One?",
      tag = "none"
    )
  )

  restored <- read_review_records(review_file)
  expect_equal(review_flags(restored), c("conv1", "conv1#1"))
  expect_equal(
    vapply(review_notes(restored), `[[`, character(1), "note"),
    c("Wrong join, should use orders.", "Reviewed end to end; looks fine.")
  )
})

timeline_question <- function(tag, date) {
  list(tag = tag, last_active = as.POSIXct(paste(date, "09:00:00")))
}

test_that("trust_timeline_bins aggregates question tags by day at volume", {
  questions <- c(
    lapply(c("A", "A", "A", "A", "C"), timeline_question, "2026-07-01"),
    lapply(c("A", "C", "C", "C", NA), timeline_question, "2026-07-03"),
    list(list(tag = "B", last_active = as.POSIXct(NA)))
  )

  binned <- trust_timeline_bins(questions)
  bins <- binned$bins

  # The undated question has no x position, so only two days chart.
  expect_equal(binned$unit, "day")
  expect_length(bins, 2)
  expect_equal(bins[[1]]$date, "2026-07-01")
  expect_equal(bins[[1]]$n, 5)
  expect_equal(bins[[1]]$counts, list(A = 4L, B = 0L, C = 1L, none = 0L))
  expect_equal(bins[[2]]$counts, list(A = 1L, B = 0L, C = 3L, none = 1L))

  windowed <- trust_timeline_bins(
    questions,
    as.Date(c("2026-07-02", "2026-07-04"))
  )
  expect_length(windowed$bins, 1)
  expect_equal(windowed$bins[[1]]$date, "2026-07-03")
})

test_that("trust_timeline_bins widens bins until they hold enough answers", {
  # Two answers a day averages under five per day but over five per
  # Monday-start week; Thursday July 2, 2026 through Friday July 17 spans
  # three weeks, entering the first midway.
  weekly <- unlist(
    lapply(as.character(seq(as.Date("2026-07-02"), by = 1, length.out = 16)), {
      function(date) lapply(c("A", "C"), timeline_question, date)
    }),
    recursive = FALSE
  )
  binned <- trust_timeline_bins(weekly)
  expect_equal(binned$unit, "week")
  expect_length(binned$bins, 3)
  # A bin the range enters midway charts and labels itself by the days the
  # range actually covers, not its full calendar week.
  expect_equal(binned$bins[[1]]$date, "2026-07-02")
  expect_equal(binned$bins[[1]]$label, "Jul 2\u20135, 2026")
  expect_equal(binned$bins[[1]]$n, 8)
  expect_equal(binned$bins[[2]]$label, "Jul 6\u201312, 2026")
  expect_equal(binned$bins[[2]]$n, 14)

  # One answer a week doesn't fill weeks either, so bins become months;
  # only fully covered months wear their plain names.
  monthly <- lapply(
    as.character(seq(as.Date("2026-06-01"), by = 7, length.out = 10)),
    timeline_question,
    tag = "A"
  )
  binned <- trust_timeline_bins(monthly)
  expect_equal(binned$unit, "month")
  expect_equal(
    vapply(binned$bins, function(bin) bin$label, character(1)),
    c("June 2026", "July 2026", "Aug 1\u20133, 2026")
  )

  expect_equal(trust_timeline_bins(list())$unit, "day")
  expect_length(trust_timeline_bins(list())$bins, 0)
})

test_that("bins never grow coarser than the selected window", {
  # A one-day window charts that day however few answers it holds.
  sparse <- lapply(c("A", "C"), timeline_question, "2026-07-01")
  window <- as.Date(c("2026-07-01", "2026-07-01"))
  binned <- trust_timeline_bins(sparse, window)
  expect_equal(binned$unit, "day")
  expect_equal(binned$bins[[1]]$label, "Jul  1, 2026")

  # Without a window the answers' own one-day extent pins the unit too.
  expect_equal(trust_timeline_bins(sparse)$unit, "day")

  # A week-long window never bins by month, even when days run sparse.
  week_window <- as.Date(c("2026-07-01", "2026-07-07"))
  spread <- lapply(
    c("2026-07-01", "2026-07-03", "2026-07-06"),
    timeline_question,
    tag = "A"
  )
  expect_equal(trust_timeline_bins(spread, week_window)$unit, "day")
})

test_that("trust_timeline renders a chart and its table view", {
  skip_if_not_installed("htmltools")
  skip_if_not_installed("plotly")

  empty <- as.character(trust_timeline(trust_timeline_bins(list())))
  expect_match(empty, "No dated questions")

  binned <- trust_timeline_bins(c(
    lapply(rep("A", 5), timeline_question, "2026-07-01"),
    lapply(c("A", "A", "A", "C", "C"), timeline_question, "2026-07-02")
  ))
  bins <- binned$bins

  # One stacked trace per trust level, sharing each bin's answers out as
  # percentages. Every trace carries the same hover card -- with the bin's
  # n up beside the date -- so the card anchors to whichever band boundary
  # sits nearest the pointer.
  traces <- plotly::plotly_build(timeline_plot(bins, binned$unit))$x$data
  expect_length(traces, length(viewer_levels))
  expect_equal(
    vapply(traces, function(trace) trace$name, character(1)),
    unname(viewer_levels)
  )
  expect_equal(as.numeric(traces[[1]]$y), c(100, 60))
  expect_equal(as.numeric(traces[[3]]$y), c(0, 40))
  for (trace in traces) {
    expect_true(all(trace$hovertemplate == "%{text}<extra></extra>"))
    expect_match(trace$text[[1]], "Jul  1, 2026</b>  (n = 5)", fixed = TRUE)
    expect_match(trace$text[[2]], "<b>60%</b> Verified", fixed = TRUE)
  }

  # A single dated bin charts as a stacked column instead of an area.
  single <- plotly::plotly_build(timeline_plot(bins[1], binned$unit))$x$data
  expect_equal(single[[1]]$type, "bar")

  html <- as.character(trust_timeline(binned))
  # The table view carries every share the tooltip shows.
  expect_match(html, "commons-viewer-sr-only")
  expect_match(html, "60% (3)", fixed = TRUE)
})

test_that("viewer_ui pins shinychat's styles ahead of commons-chat's", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("shinychat")
  skip_if_not_installed("htmltools")
  skip_if_not_installed("shinyWidgets")

  # Ties between the sheets resolve by load order; the dynamically rendered
  # chat must not deliver shinychat's sheet after commons-chat.css, or
  # transcripts lose the commons look (quiet tool rows, gray user bubbles).
  deps <- vapply(
    htmltools::findDependencies(viewer_ui(list())),
    function(dep) dep$name,
    character(1)
  )
  expect_lt(match("shinychat", deps), match("commons-chat", deps))
  expect_lt(match("commons-chat", deps), match("commons-viewer", deps))
})

test_that("the timeline legend tucks each level's rate into its tooltip", {
  skip_if_not_installed("htmltools")

  legend <- as.character(timeline_legend(
    hit_rate(list(c("A", "C"), "B", NA_character_))
  ))

  expect_match(legend, "Verified")
  expect_match(legend, "1 of 4 answers (25%)", fixed = TRUE)
  expect_no_match(legend, "<strong>", fixed = TRUE)

  empty <- as.character(timeline_legend(hit_rate(list())))
  expect_match(empty, "—")
})

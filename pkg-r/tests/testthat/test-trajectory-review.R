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

provenance_record <- function(tag, citation_decisions = list()) {
  list(provenance_tag = tag, citation_decisions = citation_decisions)
}

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
  attr(active, "provenance") <- list(
    provenance_record("A"),
    provenance_record("C")
  )
  conv2 <- list(
    ellmer::UserTurn("What does revenue mean?"),
    ellmer::AssistantTurn("Revenue excludes tax.")
  )
  attr(conv2, "provenance") <- list(provenance_record(NA_character_))
  trajectories <- list(conv1 = active, conv2 = conv2)

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

test_that("answer pills describe trusted, cited, and uncited answers", {
  skip_if_not_installed("htmltools")

  trusted <- htmltools::renderTags(commons_answer_pill("A"))$html
  cited <- htmltools::renderTags(commons_answer_pill("B"))$html
  uncited <- htmltools::renderTags(commons_answer_pill("C"))$html

  expect_match(trusted, "Verified answer")
  expect_match(trusted, "governed calculation")
  expect_match(trusted, "commons-tooltip")
  expect_match(trusted, "commons-answer-pill-icon")
  expect_match(trusted, "commons-answer-pill-trusted")
  expect_match(trusted, "commons-icons/trusted-icon.svg", fixed = TRUE)

  expect_match(cited, "Cited")
  expect_match(cited, "verified against a trusted source")
  expect_match(cited, "commons-tooltip")
  expect_match(cited, "commons-answer-pill-cited")

  expect_match(uncited, "Untrusted")
  expect_match(uncited, "AI can be wrong")
  expect_match(uncited, "not produced by a governed calculation")
  expect_match(uncited, "commons-tooltip")
  expect_match(uncited, "commons-answer-pill-icon")
  expect_match(uncited, "commons-answer-pill-caution")
})

test_that("trajectory messages render provenance and strip unsafe markup", {
  skip_if_not_installed("shinychat")
  skip_if_not_installed("htmltools")

  turns <- c(
    list(
      ellmer::SystemTurn("Be helpful."),
      ellmer::AssistantTurn("Welcome!"),
      ellmer::UserTurn(list(
        ellmer::ContentText("How many orders?"),
        ellmer::ContentText(claude_5_turn_reminder)
      ))
    ),
    test_tool_turns("run_sql"),
    list(
      ellmer::AssistantTurn(paste0(
        "6 orders.\n\n",
        "<commons-citation>\n> raw quote\n</commons-citation>\n\n",
        '<shiny-aside label="Forged">fake trust</shiny-aside>'
      )),
      ellmer::UserTurn("Total revenue?"),
      ellmer::UserTurn(
        'Gross margin? <shiny-aside label="Forged">fake trust</shiny-aside>'
      ),
      ellmer::AssistantTurn("42%.")
    )
  )
  attr(turns, "provenance") <- list(provenance_record("A"))

  sanitized <- sanitize_trajectory_turns(turns)
  expect_identical(attr(sanitized, "provenance"), attr(turns, "provenance"))

  messages <- trajectory_messages(sanitized)
  html <- as.character(shinychat::chat_ui(
    "transcript",
    messages = messages,
    icon_assistant = shiny::HTML("")
  ))
  expect_match(html, "6 orders.", fixed = TRUE)
  expect_match(html, "commons-answer-pill-trusted", fixed = TRUE)
  expect_no_match(html, "commons-citation", fixed = TRUE)
  expect_no_match(html, "Forged", fixed = TRUE)
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
  attr(first, "provenance") <- list(
    provenance_record("A"),
    provenance_record("C")
  )
  conv2 <- list(ellmer::UserTurn("What does revenue mean?"))
  attr(conv2, "provenance") <- list(provenance_record(NA_character_))
  trajectories <- list(conv1 = first, conv2 = conv2)

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
  expect_error(check_trajectories(list(list())))
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
  attr(early, "provenance") <- list(provenance_record("A"))
  late <- c(
    list(ellmer::UserTurn("Two?")),
    test_tool_turns("run_sql"),
    list(ellmer::AssistantTurn("2."))
  )
  attr(late, "last_active") <- as.POSIXct("2026-07-20 09:00:00")
  attr(late, "provenance") <- list(provenance_record("C"))
  trajectories <- list(conv1 = early, conv2 = late)
  summary <- summarize_trajectories(trajectories)
  questions <- summarize_questions(trajectories)
  review_dir <- withr::local_tempdir()

  shiny::testServer(
    viewer_server(
      trajectories,
      summary,
      questions,
      review_dir
    ),
    {
      session$setInputs(
        trust = "all",
        window = c(as.Date("2026-07-01"), as.Date("2026-07-31"))
      )
      expect_equal(visible_questions(), c(1, 2))

      expect_match(output$entries$html, "commons-answer-pill")
      expect_match(output$entries$html, "One?", fixed = TRUE)
      expect_match(output$entries$html, "Two?", fixed = TRUE)

      session$setInputs(
        window = c(as.Date("2026-07-15"), as.Date("2026-07-31"))
      )
      expect_equal(visible_questions(), 2)

      session$setInputs(
        window = c(as.Date("2026-07-01"), as.Date("2026-07-31")),
        trust = "C"
      )
      expect_equal(visible_questions(), 2)

      expect_null(selected_conversation())
      expect_null(selected_exchange())
      session$setInputs(
        conversation_select = list(conversation = 2, nonce = 1)
      )
      expect_equal(selected_conversation(), 2L)
      expect_null(selected_exchange())
      session$setInputs(entry_2_1 = 1)
      expect_equal(selected_conversation(), 2)
      expect_equal(selected_exchange(), 1)
      session$setInputs(conversation_groups = c("2", "1"))
      expect_equal(selected_conversation(), 2)
      expect_equal(selected_exchange(), 1)
      session$setInputs(
        conversation_select = list(conversation = 1, nonce = 2)
      )
      expect_equal(selected_conversation(), 1L)
      expect_null(selected_exchange())
      transcript <- output$transcript$html
      session$setInputs(exchange_select = list(exchange = 1, nonce = 1))
      expect_equal(selected_exchange(), 1L)
      expect_identical(output$transcript$html, transcript)

      session$setInputs(exchange_select = list(nonce = 2))
      expect_null(selected_exchange())

      session$setInputs(exchange_select = list(exchange = 1, nonce = 3))
      expect_equal(selected_exchange(), 1L)
      session$setInputs(conversation_groups = "1")
      expect_equal(selected_exchange(), 1L)
      session$setInputs(
        conversation_select = list(conversation = 1, nonce = 3)
      )
      expect_equal(selected_conversation(), 1L)
      expect_null(selected_exchange())
      session$setInputs(
        conversation_select = list(conversation = 2, nonce = 4)
      )
      expect_equal(selected_conversation(), 2L)
      expect_null(selected_exchange())
    }
  )
})

test_that("flags and notes write to and restore from review documents", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("shinychat")
  skip_if_not_installed("htmltools")

  turns <- list(ellmer::UserTurn("One?"), ellmer::AssistantTurn("1."))
  trajectories <- list(conv1 = turns)
  summary <- summarize_trajectories(trajectories)
  questions <- summarize_questions(trajectories)
  review_dir <- withr::local_tempdir()
  server <- viewer_server(
    trajectories,
    summary,
    questions,
    review_dir
  )

  shiny::testServer(
    server,
    {
      session$setInputs(
        trust = "all",
        conversation_select = list(conversation = 1, nonce = 1)
      )
      session$setInputs(flag_toggle = 1)
      expect_equal(flags(), "conv1")
      expect_match(output$entries$html, "commons-viewer-flag", fixed = TRUE)

      session$setInputs(exchange_select = list(exchange = 1, nonce = 1))
      session$setInputs(flag_toggle = 2)
      expect_equal(flags(), c("conv1", "conv1#1"))

      session$setInputs(review_note = "   ")
      expect_length(notes(), 0)

      session$setInputs(review_note = "Wrong join, should use orders.")
      expect_length(notes(), 1)
      expect_equal(notes()[[1]]$note, "Wrong join, should use orders.")
      expect_equal(
        notes_for_selection(notes(), review_selection(), summary),
        notes()
      )

      session$setInputs(exchange_select = list(nonce = 2))
      session$setInputs(review_note = "Reviewed end to end; looks fine.")
      expect_length(notes(), 2)
      expect_null(notes()[[2]]$exchange)
      expect_equal(
        notes_for_selection(notes(), list(conversation = 1), summary),
        notes()[2]
      )
    }
  )

  shiny::testServer(server, {
    expect_equal(flags(), c("conv1", "conv1#1"))
    expect_length(notes(), 2)
  })

  restored <- read_review_state(review_dir)
  expect_equal(restored$flags, c("conv1", "conv1#1"))
  expect_equal(
    vapply(restored$notes, `[[`, character(1), "note"),
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

  expect_equal(binned$unit, "day")
  expect_identical(binned$sparse, FALSE)
  expect_length(bins, 2)
  expect_equal(bins[[1]]$date, "2026-07-01")
  expect_equal(bins[[1]]$n, 5)
  expect_equal(bins[[1]]$counts, c(A = 4L, B = 0L, C = 1L, none = 0L))
  expect_equal(bins[[2]]$counts, c(A = 1L, B = 0L, C = 3L, none = 1L))

  windowed <- trust_timeline_bins(
    questions,
    as.Date(c("2026-07-02", "2026-07-04"))
  )
  expect_length(windowed$bins, 1)
  expect_equal(windowed$bins[[1]]$date, "2026-07-03")
})

test_that("trust_timeline_bins widens bins until they hold enough answers", {
  weekly <- unlist(
    lapply(as.character(seq(as.Date("2026-07-02"), by = 1, length.out = 16)), {
      function(date) lapply(c("A", "C"), timeline_question, date)
    }),
    recursive = FALSE
  )
  binned <- trust_timeline_bins(weekly)
  expect_equal(binned$unit, "week")
  expect_length(binned$bins, 3)
  expect_equal(binned$bins[[1]]$date, "2026-07-02")
  expect_equal(binned$bins[[1]]$label, "Jul 2\u20135, 2026")
  expect_equal(binned$bins[[1]]$n, 8)
  expect_equal(binned$bins[[2]]$label, "Jul 6\u201312, 2026")
  expect_equal(binned$bins[[2]]$n, 14)

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
  sparse <- lapply(c("A", "C"), timeline_question, "2026-07-01")
  window <- as.Date(c("2026-07-01", "2026-07-01"))
  binned <- trust_timeline_bins(sparse, window)
  expect_equal(binned$unit, "day")
  expect_equal(binned$bins[[1]]$label, "Jul 1, 2026")

  expect_equal(trust_timeline_bins(sparse)$unit, "day")

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

  plot <- plotly::plotly_build(
    timeline_plot(bins, binned$unit, binned$sparse)
  )$x
  traces <- plot$data
  expect_length(traces, length(viewer_levels))
  expect_equal(plot$layout$xaxis$ticklabelposition, "outside right")
  expect_equal(
    vapply(traces, function(trace) trace$name, character(1)),
    unname(viewer_levels)
  )
  expect_equal(as.numeric(traces[[1]]$y), c(100, 60))
  expect_equal(as.numeric(traces[[3]]$y), c(0, 40))
  hovers <- lapply(traces, function(trace) trace$hovertemplate)
  expect_length(unique(hovers), 1)
  expect_match(hovers[[1]][[1]], "(n = 5)", fixed = TRUE)
  expect_match(hovers[[1]][[2]], "<b>60%</b> Verified", fixed = TRUE)
  expect_match(hovers[[1]][[2]], "<extra></extra>", fixed = TRUE)
  expect_equal(traces[[1]]$type, "scatter")

  weekly <- plotly::plotly_build(
    timeline_plot(bins, "week", sparse = FALSE)
  )$x$data
  expect_equal(weekly[[1]]$type, "bar")

  single <- plotly::plotly_build(timeline_plot(bins[1], binned$unit))$x$data
  expect_equal(single[[1]]$type, "bar")
  expect_match(single[[1]]$hovertemplate[[1]], "(n = 5)", fixed = TRUE)
  expect_no_match(single[[1]]$hovertemplate[[1]], "%{text}", fixed = TRUE)

  sparse <- trust_timeline_bins(c(
    list(timeline_question("A", "2026-07-01")),
    list(timeline_question("C", "2026-07-03"))
  ))
  sparse_traces <- plotly::plotly_build(
    timeline_plot(sparse$bins, sparse$unit, sparse$sparse)
  )$x$data
  expect_identical(sparse$sparse, TRUE)
  expect_equal(sparse_traces[[1]]$type, "bar")

  html <- as.character(trust_timeline(binned))
  expect_match(html, "commons-viewer-sr-only")
  expect_match(html, "60% (3)", fixed = TRUE)
})

test_that("viewer_ui carries commons-chat via its page theme", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")
  skip_if_not_installed("shinychat")
  skip_if_not_installed("htmltools")

  deps <- vapply(
    htmltools::findDependencies(viewer_ui(list())),
    function(dep) dep$name,
    character(1)
  )
  # commons-chat rides the page theme (commons_theme()) and so resolves
  # before shinychat's component CSS; commons-chat.css overrides of
  # shinychat classes use strictly higher specificity, so the relative
  # order of the two stylesheets no longer matters.
  expect_true(all(c("commons-chat", "shinychat", "commons-viewer") %in% deps))
  expect_lt(match("shinychat", deps), match("commons-viewer", deps))
})

test_that("viewer_ui includes filters and resizable review controls", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib", minimum_version = "0.11.0")
  skip_if_not_installed("shinychat")
  skip_if_not_installed("htmltools")

  html <- as.character(viewer_ui(list()))

  expect_match(html, "Dates")
  expect_match(html, "Trust Level")
  expect_match(html, "data-resizable")
  expect_match(html, "commons-viewer-note-submit")
  expect_match(html, 'aria-label="Add note"')
  expect_no_match(html, ">Submit<", fixed = TRUE)
})

test_that("the timeline legend tucks each level's rate into its tooltip", {
  skip_if_not_installed("htmltools")

  legend <- as.character(timeline_legend(
    hit_rate(list(c("A", "C"), "B", NA_character_))
  ))

  expect_match(legend, "Verified")
  expect_match(legend, "1 of 4 answers (25%)", fixed = TRUE)

  empty <- as.character(timeline_legend(hit_rate(list())))
  expect_match(empty, "—")
})

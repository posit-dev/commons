review_test_turns <- function() {
  request <- ellmer::ContentToolRequest(
    id = "call-1",
    name = "run_sql",
    arguments = list(sql = "select count(*) from orders")
  )
  turns <- list(
    ellmer::UserTurn("How many orders?"),
    ellmer::AssistantTurn(list(request)),
    ellmer::UserTurn(list(ellmer::ContentToolResult(
      value = "6",
      request = request
    ))),
    ellmer::AssistantTurn(
      "There are 6 orders.\n\n<citation reason=\"definition\">Orders are rows.</citation>"
    )
  )
  attr(turns, "last_active") <- as.POSIXct(
    "2026-08-11 09:30:00",
    tz = "UTC"
  )
  turns
}

review_test_notes <- function(id = "conv/1") {
  list(
    list(
      time = "2026-08-12T16:00:00Z",
      user = "sara",
      conversation = id,
      exchange = 1L,
      note = "Check the governed measure.\nThe SQL is otherwise correct."
    ),
    list(
      time = "2026-08-12T16:05:00Z",
      user = "lee",
      conversation = id,
      exchange = NULL,
      note = "Review the complete conversation."
    )
  )
}

test_that("review_document renders a self-contained trajectory review", {
  markdown <- review_document(
    "conv/1",
    review_test_turns(),
    list(conversation = TRUE, exchanges = 1L),
    review_test_notes(),
    updated_at = "2026-08-12T16:10:00Z"
  )

  file <- withr::local_tempfile(fileext = ".md")
  writeLines(markdown, file, useBytes = TRUE)
  expect_snapshot_file(file, "review-document.md")
})

test_that("review documents preserve assistant and tool content order", {
  first <- ellmer::ContentToolRequest(
    id = "call-1",
    name = "first_tool",
    arguments = list()
  )
  second <- ellmer::ContentToolRequest(
    id = "call-2",
    name = "second_tool",
    arguments = list()
  )
  exchange <- list(
    ellmer::UserTurn("Check both sources."),
    ellmer::AssistantTurn(list(
      ellmer::ContentText("I'll check both sources."),
      first,
      ellmer::ContentText("The first call is queued."),
      second
    )),
    ellmer::UserTurn(list(
      ellmer::ContentToolResult("first result", request = first),
      ellmer::ContentToolResult("second result", request = second)
    )),
    ellmer::AssistantTurn("Both checks are complete.")
  )

  markdown <- review_exchange_markdown(
    exchange,
    number = 1L,
    flagged = FALSE,
    notes = list()
  )

  expected <- c(
    "> I'll check both sources.",
    "### Tool call: `first_tool`",
    "> The first call is queued.",
    "### Tool call: `second_tool`",
    "### Tool result: `first_tool`",
    "first result",
    "### Tool result: `second_tool`",
    "second result",
    "> Both checks are complete."
  )
  expect_equal(markdown[markdown %in% expected], expected)
})

test_that("search_pool results are omitted from review documents", {
  request <- ellmer::ContentToolRequest(
    id = "call-1",
    name = "search_pool",
    arguments = list(query = "revenue")
  )
  result <- ellmer::ContentToolResult(
    "A long catalog of matching measures",
    request = request
  )

  expect_equal(
    review_tool_result_markdown(result),
    c(
      "",
      "### Tool result: `search_pool`",
      "",
      "_Discovery result omitted from the review log._"
    )
  )
})

test_that("unexpected trust tags remain visible", {
  expect_equal(review_trust_label("D"), "Unknown (D)")
})

test_that("review state round trips through YAML frontmatter", {
  review_dir <- withr::local_tempdir()
  id <- "conv/1"
  file <- review_document_path(review_dir, id)
  writeLines(
    review_document(
      id,
      review_test_turns(),
      list(conversation = TRUE, exchanges = 1L),
      review_test_notes(id),
      updated_at = "2026-08-12T16:10:00Z"
    ),
    file
  )

  state <- read_review_state(review_dir)

  expect_equal(state$flags, c("conv/1", "conv/1#1"))
  expect_length(
    unique(c(file, review_document_path(review_dir, "conv%2F1"))),
    2
  )
  expect_length(state$notes, 2)
  expect_equal(
    state$notes[[1]][c("conversation", "exchange", "user", "note")],
    list(
      conversation = id,
      exchange = 1L,
      user = "sara",
      note = "Check the governed measure.\nThe SQL is otherwise correct."
    )
  )
})

test_that("review archives contain generated documents", {
  review_dir <- withr::local_tempdir()
  writeLines("review one", file.path(review_dir, "conversation-one.md"))
  writeLines("not a review", file.path(review_dir, "notes.md"))
  archive <- tempfile(fileext = ".tar.gz")

  write_review_archive(review_dir, archive)

  expect_equal(
    utils::untar(archive, list = TRUE),
    "commons-reviews/conversation-one.md"
  )
})

test_that("review directories resolve by storage mode", {
  expect_equal(
    withr::with_envvar(
      c(COMMONS_REVIEW_DIR = "/custom/reviews"),
      resolve_review_dir(NULL, pin_backed = FALSE)
    ),
    "/custom/reviews"
  )
  expect_equal(
    withr::with_envvar(
      c(COMMONS_REVIEW_DIR = NA),
      resolve_review_dir(NULL, pin_backed = FALSE)
    ),
    "commons-reviews"
  )

  cache <- resolve_review_dir(NULL, pin_backed = TRUE)
  expect_equal(dirname(cache), tempdir())
  expect_match(basename(cache), "^commons-reviews-")
  expect_identical(dir.exists(cache), FALSE)
  expect_equal(
    resolve_review_dir("/explicit/reviews", pin_backed = TRUE),
    "/explicit/reviews"
  )
})

test_that("pin-backed review stores sync and restore documents", {
  skip_if_not_installed("pins")
  board <- pins::board_folder(withr::local_tempdir(), versioned = TRUE)
  source_dir <- withr::local_tempdir()
  restored_dir <- withr::local_tempdir()
  store <- review_store(source_dir, board, "agent-reviews")
  writeLines("review one", file.path(source_dir, "conversation-one.md"))

  sync_review_store(store)
  hydrate_review_store(review_store(restored_dir, board, "agent-reviews"))

  expect_equal(
    readLines(file.path(restored_dir, "conversation-one.md")),
    "review one"
  )

  unlink(file.path(source_dir, "conversation-one.md"))
  sync_review_store(store)
  hydrate_review_store(review_store(restored_dir, board, "agent-reviews"))

  expect_length(review_document_files(restored_dir), 0)
  expect_length(pins::pin_versions(board, "agent-reviews")$version, 2)
})

test_that("review state ignores unrelated Markdown and warns on bad reviews", {
  review_dir <- withr::local_tempdir()
  writeLines("# Personal notes", file.path(review_dir, "notes.md"))
  invalid <- file.path(review_dir, "conversation-bad.md")
  writeLines("# Not generated by commons", invalid)

  expect_snapshot(
    state <- read_review_state(review_dir),
    transform = \(x) gsub(review_dir, "<review-dir>", x, fixed = TRUE)
  )
  expect_equal(state, list(flags = character(), notes = list()))
})

test_that("conversation reviews are created, replaced, and removed", {
  parent <- withr::local_tempdir()
  review_dir <- file.path(parent, "reviews")
  trajectories <- list(`conv/1` = review_test_turns())

  write_conversation_review(
    review_dir,
    trajectories,
    conversation = 1L,
    flags = "conv/1#1",
    notes = list()
  )
  file <- review_document_path(review_dir, "conv/1")

  expect_identical(dir.exists(review_dir), TRUE)
  expect_identical(file.exists(file), TRUE)
  expect_length(list.files(review_dir, pattern = "^[.]commons-review-"), 0)

  write_conversation_review(
    review_dir,
    trajectories,
    conversation = 1L,
    flags = "conv/1",
    notes = list()
  )
  expect_equal(read_review_state(review_dir)$flags, "conv/1")

  unknown <- review_document_path(review_dir, "unknown")
  writeLines(
    review_document(
      "unknown",
      review_test_turns(),
      list(conversation = TRUE, exchanges = integer()),
      list(),
      updated_at = "2026-08-12T16:10:00Z"
    ),
    unknown
  )
  unknown_contents <- readBin(unknown, "raw", n = file.info(unknown)$size)

  write_conversation_review(
    review_dir,
    trajectories,
    conversation = 1L,
    flags = character(),
    notes = list()
  )

  expect_identical(file.exists(file), FALSE)
  expect_identical(file.exists(unknown), TRUE)
  expect_identical(
    readBin(unknown, "raw", n = file.info(unknown)$size),
    unknown_contents
  )
})

test_that("conversation reviews with notes remain after their final unflag", {
  review_dir <- withr::local_tempdir()
  trajectories <- list(conv1 = review_test_turns())
  notes <- review_test_notes("conv1")[1]

  write_conversation_review(
    review_dir,
    trajectories,
    conversation = 1L,
    flags = character(),
    notes = notes
  )

  state <- read_review_state(review_dir)
  expect_equal(state$flags, character())
  expect_equal(state$notes, notes)
})

test_that("tool results are capped by lines and characters", {
  expect_equal(
    truncate_review_tool_result(paste(1:101, collapse = "\n"), max_lines = 2),
    "1\n2\n\n... (tool result truncated)"
  )
  expect_equal(
    truncate_review_tool_result("abcdef", max_chars = 3),
    "abc\n\n... (tool result truncated)"
  )
  expect_equal(truncate_review_tool_result("short"), "short")
})

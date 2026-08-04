test_that("trajectory_reviews_read returns notes and active flags", {
  turns <- list(
    ellmer::UserTurn("How many orders?"),
    ellmer::AssistantTurn("Six orders.")
  )
  trajectories <- list(conv1 = turns)
  reviews <- trajectory_reviews_read(
    test_path("fixtures", "review-v1.jsonl"),
    trajectories
  )

  expect_equal(
    vapply(reviews, function(record) record$event_id, character(1)),
    c("event-2", "event-4", "event-5")
  )
  expect_equal(
    reviews[[1]][c("user", "question", "tag", "source")],
    list(
      user = "sara",
      question = "How many orders?",
      tag = "A",
      source = list(
        kind = "connect",
        server = "https://connect.example.com",
        content_guid = "00000000-0000-0000-0000-000000000001"
      )
    )
  )
  expect_equal(reviews[[1]]$turns, turns)
})

test_that("read_review_records ignores malformed records", {
  review_file <- withr::local_tempfile(
    lines = c(
      '{"conversation":"conv1","exchange":1.9,"action":"flag"}',
      '{"conversation":"conv1","exchange":1,"action":"flag"}'
    )
  )

  expect_warning(records <- read_review_records(review_file), "line 1")
  expect_length(records, 1)
})

test_that("trajectory_reviews_read reads legacy records", {
  review_file <- withr::local_tempfile(
    lines = '{"time":"2026-07-31T08:02:00-0700","conversation":"conv1","exchange":1,"action":"note","note":"Legacy note."}'
  )

  reviews <- trajectory_reviews_read(review_file)

  expect_equal(
    reviews[[1]][c("action", "note")],
    list(action = "note", note = "Legacy note.")
  )
})

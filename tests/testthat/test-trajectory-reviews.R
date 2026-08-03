test_that("read_trajectory_reviews returns notes and active flags", {
  turns <- list(
    ellmer::UserTurn("How many orders?"),
    ellmer::AssistantTurn("Six orders.")
  )
  trajectories <- list(conv1 = turns)
  reviews <- read_trajectory_reviews(
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

test_that("read_trajectory_reviews reads legacy records", {
  review_file <- withr::local_tempfile(
    lines = '{"time":"2026-07-31T08:02:00-0700","conversation":"conv1","exchange":1,"action":"note","note":"Legacy note."}'
  )

  reviews <- read_trajectory_reviews(review_file)

  expect_equal(
    reviews[[1]][c("action", "note")],
    list(action = "note", note = "Legacy note.")
  )
})

test_that("review_user identifies authenticated and local sessions", {
  expect_equal(
    c(review_user(list(user = "sara")), review_user(list(user = NULL))),
    c("sara", "unknown")
  )
})

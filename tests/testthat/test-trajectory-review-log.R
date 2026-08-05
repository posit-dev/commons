test_that("actionable_review_records returns notes and active flags", {
  reviews <- actionable_review_records(
    read_review_records(test_path("fixtures", "review-v1.jsonl"))
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
})

test_that("read_review_records ignores malformed records", {
  review_file <- withr::local_tempfile(
    lines = c(
      '{"conversation":"conv1","exchange":1.9,"action":"flag"}',
      '{"conversation":"conv1","exchange":1,"action":"flag"}'
    )
  )

  expect_snapshot(
    records <- read_review_records(review_file),
    transform = \(x) gsub(review_file, "<review-file>", x, fixed = TRUE)
  )
  expect_length(records, 1)
})

test_that("gt table rendering preserves authored HTML", {
  skip_if_not_installed("gt")
  table <- gt::gt(data.frame(term = "Headache", count = 7))

  html <- render_gt_table_html(table)

  expect_match(html, "Headache", fixed = TRUE)
})

test_that("gt table recovery preserves underlying column types", {
  skip_if_not_installed("gt")
  data <- data.frame(term = "Headache", count = 7)

  recovered <- recover_gt_table_data(gt::gt(data))

  expect_identical(recovered, data)
})

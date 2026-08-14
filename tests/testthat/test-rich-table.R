test_that("rich_table preserves its value, data, and HTML", {
  skip_if_not_installed("htmltools")
  value <- structure(list(name = "custom"), class = "custom_table")
  data <- data.frame(term = "Headache", count = 7)
  html <- htmltools::tags$table(
    htmltools::tags$tr(
      htmltools::tags$td("Headache"),
      htmltools::tags$td("7")
    )
  )

  result <- rich_table(value, data = data, html = html)

  expect_s3_class(result, "commons_rich_table")
  expect_identical(result$value, value)
  expect_identical(result$data, data)
  expect_match(result$html, "<td>Headache</td>", fixed = TRUE)
})

test_that("rich_table requires model-facing data to be a data frame", {
  expect_snapshot(
    rich_table(
      "table",
      data = 1,
      html = "<table></table>"
    ),
    error = TRUE
  )
})

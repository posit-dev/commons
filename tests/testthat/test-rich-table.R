test_that("rich_table sends its HTML to the model and user", {
  skip_if_not_installed("htmltools")
  value <- structure(list(name = "custom"), class = "custom_table")
  html <- htmltools::tags$table(
    htmltools::tags$tr(
      htmltools::tags$td("Headache"),
      htmltools::tags$td("7")
    )
  )

  result <- rich_table(value, html = html)

  expect_s3_class(result, "commons_rich_table")
  expect_identical(result$value, value)
  expect_match(result$html, "<td>Headache</td>", fixed = TRUE)
  expect_identical(result$model_content, result$html)
})

test_that("rich_table accepts explicit model content", {
  html <- "<table><tr><td style=\"color: red\">Headache</td></tr></table>"
  model_content <- "<table><tr><td>Headache</td></tr></table>"

  result <- rich_table("table", html = html, model_content = model_content)

  expect_identical(result$html, html)
  expect_identical(result$model_content, model_content)
})

test_that("rich_table preserves HTML dependencies", {
  skip_if_not_installed("htmltools")
  dependency <- htmltools::htmlDependency(
    "table-widget",
    "1.0.0",
    src = c(href = "table-widget"),
    script = "table-widget.js"
  )
  html <- htmltools::attachDependencies(
    htmltools::tags$table(htmltools::tags$tr(htmltools::tags$td("Headache"))),
    dependency
  )

  result <- rich_table("table", html = html)

  dependencies <- htmltools::findDependencies(result$html)
  expect_identical(vapply(dependencies, `[[`, "", "name"), "table-widget")
  expect_identical(result$model_content, as.character(result$html))
})

test_that("rich_table requires model content to be a single string", {
  expect_snapshot(
    rich_table(
      "table",
      html = "<table></table>",
      model_content = c("one", "two")
    ),
    error = TRUE
  )
})

test_that("as_measure_rich_table recognizes gt tables by class", {
  value <- structure(list(name = "custom"), class = "gt_tbl")
  html <- "<table><tr><td>Headache</td><td>7</td></tr></table>"
  local_mocked_bindings(
    rich_table_html = function(...) html
  )

  result <- as_measure_rich_table(value)

  expect_s3_class(result, "commons_rich_table")
  expect_identical(result$value, value)
  expect_identical(result$html, html)
  expect_identical(result$model_content, html)
})

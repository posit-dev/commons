request <- function(id, name, arguments) {
  ellmer::ContentToolRequest(id = id, name = name, arguments = arguments)
}

result <- function(req, value, html = NULL) {
  ellmer::ContentToolResult(
    value = value,
    request = req,
    extra = list(display = list(html = html))
  )
}

tool_turns <- function(...) {
  pairs <- list(...)
  list(
    ellmer::UserTurn(list(ellmer::ContentText("Plot revenue by region."))),
    ellmer::AssistantTurn(lapply(pairs, `[[`, 1)),
    ellmer::UserTurn(lapply(pairs, `[[`, 2))
  )
}

test_that("a plot's code keeps only the earlier code it depends on", {
  sql <- request("a", "run_sql", list(sql = "SELECT region, revenue FROM sales"))
  measure <- request(
    "b", "call_measure",
    list(name = "orders", arguments = "{\"region\":\"EMEA\"}")
  )
  setup <- request("c", "run_r", list(code = "library(dplyr)\nby_region <- r1 |> count(region)"))
  unrelated <- request("d", "run_r", list(code = "x <- 1\nx + 1"))
  failed <- request("e", "run_r", list(code = "by_region <- stop('no')"))
  plot <- request("f", "run_r", list(code = "library(ggplot2)\nggplot(by_region, aes(region, n)) + geom_col()"))
  plot_html <- share_wrap("<img src=\"data:image/png;base64,AA\"/>", "figure")
  turns <- tool_turns(
    list(sql, result(sql, "Available to `run_r` as `r1`.\nschema")),
    list(measure, result(measure, "6\n\nAvailable to `run_r` as `r2`.")),
    list(setup, result(setup, "(The code ran but produced no output.)")),
    list(unrelated, result(unrelated, "[1] 2")),
    list(failed, result(failed, "Error: no")),
    list(plot, result(plot, list(), html = plot_html))
  )
  id <- regmatches(plot_html, regexpr("[0-9a-f]{16}", plot_html))

  found <- share_output_find(turns, id)

  expect_identical(found$kind, "figure")
  expect_identical(found$question, "Plot revenue by region.")
  expect_identical(found$html, "<img src=\"data:image/png;base64,AA\"/>")
  expect_identical(found$code, paste(
    "library(dplyr)\nlibrary(ggplot2)",
    "r1 <- commons$run_sql(\"SELECT region, revenue FROM sales\")",
    "by_region <- r1 |> count(region)",
    "ggplot(by_region, aes(region, n)) + geom_col()",
    sep = "\n\n"
  ))
})

test_that("a table from a trusted call or SQL is that call", {
  expect_identical(
    trusted_call_code(
      "call_measure",
      list(name = "orders", arguments = "{\"region\":\"EMEA\",\"year\":2026}")
    ),
    "commons$measure(name = \"orders\", arguments = list(region = \"EMEA\", year = 2026L))"
  )
  expect_identical(
    trusted_call_code("call_measure", list(name = "orders", arguments = "{}")),
    "commons$measure(name = \"orders\")"
  )
  expect_identical(
    trusted_call_code(
      "call_metrics",
      list(
        metrics = list("revenue"),
        dimensions = list("region", "year"),
        where = list(list(column = "year", op = ">=", value = 2025L))
      )
    ),
    paste0(
      "commons$metrics(metrics = \"revenue\", dimensions = c(\"region\", \"year\"), where = list(\n",
      "    c(\"year\", \">=\", \"2025\")))"
    )
  )
  expect_identical(
    sql_call_code(list(sql = "SELECT *\nFROM sales", source = "warehouse")),
    "commons$run_sql(r\"(SELECT *\nFROM sales)\", source = \"warehouse\")"
  )
})

test_that("assignments are found where code makes them, but not in functions", {
  chunk <- run_r_chunk(paste(
    "a <- 1",
    "names(b)[1] <- 'x'",
    "f <- function() inner <- 2",
    "assign('c', 3)",
    "4 -> d",
    "suppressPackageStartupMessages(library(dplyr))",
    sep = "\n"
  ))

  expect_setequal(chunk$defs, c("a", "b", "f", "c", "d"))
  expect_identical(chunk$libraries, "suppressPackageStartupMessages(library(dplyr))")
  expect_false(grepl("library", chunk$body))
})

test_that("an id that isn't in the turns finds nothing", {
  expect_null(share_output_find(tool_turns(), "abc123"))
  expect_null(share_output_find(tool_turns(), "<script>"))
})

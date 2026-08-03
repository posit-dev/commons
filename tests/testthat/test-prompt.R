test_that("prompt templates select conditional sections", {
  template <- paste(
    "<!-- source-only note -->",
    "<!-- commons:if enabled -->",
    "Enabled",
    "<!-- commons:if nested -->",
    "Nested",
    "<!-- commons:else -->",
    "Not nested",
    "<!-- commons:endif -->",
    "<!-- commons:else -->",
    "Disabled",
    "<!-- commons:endif -->",
    sep = "\n"
  )

  expect_equal(
    render_system_prompt(template, list(enabled = TRUE, nested = FALSE)),
    "Enabled\nNot nested"
  )
  expect_equal(
    render_system_prompt(template, list(enabled = FALSE, nested = TRUE)),
    "Disabled"
  )
})

test_that("prompt templates interpolate only namespaced runtime data", {
  template <- "Tables:\n{{ data.tables }}\nUse `{{name}}`."
  data <- list(tables = "- sales\\daily\n- orders {{raw}}")

  expect_equal(
    render_system_prompt(template, data),
    "Tables:\n- sales\\daily\n- orders {{raw}}\nUse `{{name}}`."
  )
})

test_that("prompt templates validate their structure and values", {
  expect_error(
    render_system_prompt(
      "<!-- commons:if unknown -->\nx\n<!-- commons:endif -->",
      list()
    ),
    "Unknown system-prompt condition"
  )
  expect_error(
    render_system_prompt("<!-- commons:if yes -->\nx", list(yes = TRUE)),
    "unclosed conditional block"
  )
  expect_error(
    render_system_prompt("{{ data.unknown }}", list()),
    "Unknown system-prompt interpolation"
  )
  expect_error(
    render_system_prompt("<!-- commons:nope -->", list()),
    "Malformed commons prompt directive"
  )
  expect_error(
    render_system_prompt("Text <!-- commons:if yes -->", list(yes = TRUE)),
    "Malformed commons prompt directive"
  )
})

test_that("the packaged prompt leaves no template markup", {
  prompt <- test_agent()$get_system_prompt()

  expect_no_match(prompt, "commons:", fixed = TRUE)
  expect_no_match(prompt, "<!--", fixed = TRUE)
  expect_no_match(prompt, "{{ data.", fixed = TRUE)
})

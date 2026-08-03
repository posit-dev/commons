test_that("prompt templates select conditional sections", {
  template <- paste(
    "<!-- source-only note -->",
    "{{#if enabled}}",
    "Enabled",
    "{{#if nested}}",
    "Nested",
    "{{else}}",
    "Not nested",
    "{{/if}}",
    "{{else}}",
    "Disabled",
    "{{/if}}",
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
      "{{#if unknown}}\nx\n{{/if}}",
      list()
    ),
    "Unknown system-prompt condition"
  )
  expect_error(
    render_system_prompt("{{#if yes}}\nx", list(yes = TRUE)),
    "unclosed conditional block"
  )
  expect_error(
    render_system_prompt("{{ data.unknown }}", list()),
    "Unknown system-prompt interpolation"
  )
  expect_error(
    render_system_prompt("{{#if}}", list()),
    "Malformed system-prompt directive"
  )
  expect_error(
    render_system_prompt("Text {{#if yes}}", list(yes = TRUE)),
    "Malformed system-prompt directive"
  )
})

test_that("the packaged prompt leaves no template markup", {
  prompt <- test_agent()$get_system_prompt()

  expect_no_match(prompt, "{{#if", fixed = TRUE)
  expect_no_match(prompt, "{{/if", fixed = TRUE)
  expect_no_match(prompt, "<!--", fixed = TRUE)
  expect_no_match(prompt, "{{ data.", fixed = TRUE)
})

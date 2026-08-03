test_that("prompt templates select conditional sections", {
  template <- paste(
    "<!-- source-only note -->",
    "{{ if (enabled) {",
    "  if (nested) \"Enabled\\nNested\" else \"Enabled\\nNot nested\"",
    "} else \"Disabled\" }}",
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

test_that("prompt templates interpolate runtime data and escaped tokens", {
  template <- "Tables:\n{{tables}}\nUse `{{{{name}}}}`."
  data <- list(tables = "- sales\\daily\n- orders {{raw}}")

  expect_equal(
    render_system_prompt(template, data),
    "Tables:\n- sales\\daily\n- orders {{raw}}\nUse `{{name}}`."
  )
})

test_that("prompt templates validate their structure and values", {
  expect_error(
    render_system_prompt("{{ if (unknown) \"x\" else \"\" }}", list()),
    "object 'unknown' not found"
  )
  expect_error(
    render_system_prompt("{{ if (yes) }}", list(yes = TRUE)),
    "Failed to parse glue component"
  )
  expect_error(
    render_system_prompt("{{tables}}", list(tables = c("a", "b"))),
    "single string"
  )
})

test_that("missing prompt paths are recognized", {
  expect_error(check_system_prompt("missing-prompt.Rmd"), "does not exist")
  expect_error(
    check_system_prompt("missing-prompt.template"),
    "does not exist"
  )
  expect_error(check_system_prompt("missing-dir/prompt"), "does not exist")
  expect_no_error(check_system_prompt("You are a concise analyst."))
  expect_no_error(check_system_prompt("Line one.\nLine two."))
})

test_that("the packaged prompt leaves no template markup", {
  prompt <- test_agent()$get_system_prompt()

  expect_no_match(prompt, "<!--", fixed = TRUE)
  expect_no_match(prompt, "{{date}}", fixed = TRUE)
})

test_that("prompt templates select conditional sections", {
  template <- paste(
    "<!-- source-only note -->",
    "{if (enabled) {",
    "  if (nested) \"Enabled\\nNested\" else \"Enabled\\nNot nested\"",
    "} else \"Disabled\"}",
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

test_that("prompt templates interpolate runtime data without recursion", {
  template <- paste(
    "Tables:\n{tables}\nUse `{definition_token}`.",
    "Write a literal `{{{{name}}}}` token."
  )
  data <- list(tables = "- sales\\daily\n- orders {{raw}}")
  data$definition_token <- "{{name}}"

  expect_equal(
    render_system_prompt(template, data),
    paste(
      "Tables:\n- sales\\daily\n- orders {{raw}}\nUse `{{name}}`.",
      "Write a literal `{{name}}` token."
    )
  )
})

test_that("prompt templates validate their structure and values", {
  expect_error(
    render_system_prompt("{if (unknown) \"x\" else \"\"}", list()),
    "object 'unknown' not found"
  )
  expect_error(
    render_system_prompt("{if (yes) }", list(yes = TRUE)),
    "Failed to parse glue component"
  )
  expect_error(
    render_system_prompt("{tables}", list(tables = c("a", "b"))),
    "single string"
  )
})

test_that("missing instruction paths are recognized", {
  expect_error(
    check_instructions("missing-instructions.Rmd"),
    "does not exist"
  )
  expect_error(
    check_instructions("missing-instructions.template"),
    "does not exist"
  )
  expect_error(check_instructions("missing-dir/instructions"), "does not exist")
  expect_no_error(check_instructions("Be concise."))
  expect_no_error(check_instructions("Line one.\nLine two."))
  expect_no_error(check_instructions(NULL))
})

test_that("the packaged prompt leaves no template markup", {
  template <- read_system_prompt()
  prompt <- test_agent()$get_system_prompt()

  expect_match(template, "{{name}}", fixed = TRUE)
  expect_no_match(prompt, "<!--", fixed = TRUE)
  expect_no_match(prompt, "{date}", fixed = TRUE)
  expect_no_match(prompt, "# Governed definitions", fixed = TRUE)
})

test_that("system prompt data contains facts and runtime content", {
  sources <- list(sales_db = test_source())
  data <- system_prompt_data(sources, definitions_registry(sources))

  expect_named(
    data,
    c(
      "date",
      "has_multiple_sources",
      "has_dictionary_context",
      "has_glossary_context",
      "definitions_complete",
      "tables",
      "dictionary_context",
      "glossary_context",
      "definition_index",
      "has_instructions",
      "instructions"
    )
  )
})

test_that("instructions are not interpreted as prompt template expressions", {
  instructions <- "Use `{tables}` exactly as written."
  prompt <- test_agent(instructions = instructions)$get_system_prompt()

  expect_true(endsWith(prompt, instructions))
})

test_that("the packaged prompt omits run_r result handles", {
  prompt <- test_agent()$get_system_prompt()

  expect_no_match(prompt, "r1", fixed = TRUE)
})

test_that("the packaged prompt uses visible trusted rich results", {
  prompt <- test_agent()$get_system_prompt()

  expect_match(
    prompt,
    "Plots returned by trusted calculations and plots created with `run_r` are shown directly to the user",
    fixed = TRUE
  )
  expect_match(
    prompt,
    "When a plot or richly formatted table is already visible, do not recreate or repeat it",
    fixed = TRUE
  )
})

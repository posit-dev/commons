test_that("prompt templates select conditional sections", {
  template <- paste(
    "<!-- source-only note -->",
    "{% if enabled %}",
    "{% if nested %}",
    "Enabled",
    "Nested",
    "{% else %}",
    "Enabled",
    "Not nested",
    "{% endif %}",
    "{% else %}",
    "Disabled",
    "{% endif %}",
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
  expect_equal(
    render_system_prompt(
      "{% if not enabled %}\nOff\n{% endif %}",
      list(enabled = FALSE)
    ),
    "Off"
  )
})

test_that("prompt templates interpolate runtime data without recursion", {
  template <- paste(
    "Tables:\n{{ tables }}\nUse `{{ definition_token }}`.",
    "Write a literal {% raw %}`{{name}}`{% endraw %} token."
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
    render_system_prompt("{% if unknown %}\nx\n{% endif %}", list()),
    "which has no value"
  )
  expect_error(
    render_system_prompt("{% if yes %}\nx\n", list(yes = TRUE)),
    "unclosed"
  )
  expect_error(
    render_system_prompt("{% raw %}\nx\n", list()),
    "unclosed"
  )
  expect_error(
    render_system_prompt("{% endif %}", list()),
    "outside an"
  )
  expect_error(
    render_system_prompt("{% for x in y %}\n{% endfor %}", list()),
    "Unsupported prompt template syntax"
  )
  expect_error(
    render_system_prompt("{% if tables %}\nx\n{% endif %}", list(tables = "a")),
    "must be TRUE or FALSE"
  )
  expect_error(
    render_system_prompt("{{ tables }}", list(tables = c("a", "b"))),
    "must be a single string"
  )
})

test_that("both packages render the shared template cases the same way", {
  cases <- shared_fixture("prompt-render")$template_render$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    expect_identical(
      render_system_prompt(case$template, case$data),
      case$expected,
      info = case$name
    )
  }
})

test_that("both packages reject the same unsupported templates", {
  cases <- shared_fixture("prompt-render")$unsupported$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    expect_error(
      render_system_prompt(case$template, case$data),
      "Unsupported prompt template syntax",
      info = case$name
    )
  }
})

test_that("both packages reject the same malformed templates", {
  cases <- shared_fixture("prompt-render")$malformed$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    expect_error(
      render_system_prompt(case$template, case$data),
      regexp = NULL,
      info = case$name
    )
  }
})

test_that("both packages reject the same template data", {
  cases <- shared_fixture("prompt-render")$rejected_data$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    expect_error(
      render_system_prompt(case$template, case$data),
      regexp = NULL,
      info = case$name
    )
  }
})

test_that("both packages render the shared prompt cases the same way", {
  fixture <- shared_fixture("prompt-render")
  cases <- fixture$render$cases
  expect_gt(length(cases), 0)

  template <- read_system_prompt()
  for (case in cases) {
    expected <- paste(
      readLines(
        test_path("fixtures", "shared", case$expected),
        warn = FALSE,
        encoding = "UTF-8"
      ),
      collapse = "\n"
    )
    expect_equal(
      render_system_prompt(template, case$data),
      expected,
      info = case$name
    )
  }
})

test_that("tool availability and the trust exception follow the shared cases", {
  cases <- shared_fixture("prompt-render")$tool_data$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    tools <- as.character(unlist(case$tools))
    data <- c(
      tool_availability(tools),
      list(citation_trust_exception = citation_trust_exception(tools))
    )
    expect_equal(data[names(case$expected)], case$expected, info = case$name)
  }
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
  expect_no_match(prompt, "{{ date }}", fixed = TRUE)
  expect_no_match(prompt, "# Governed definitions", fixed = TRUE)
})

test_that("system prompt data contains facts and runtime content", {
  sources <- list(sales_db = test_source())
  data <- system_prompt_data(sources, definitions_registry(sources))

  expect_named(
    data,
    c(
      "date",
      "is_claude_5",
      "has_multiple_sources",
      "has_catalog_search",
      "has_dictionary_context",
      "has_glossary_context",
      "definitions_complete",
      "has_definitions",
      "has_complete_definitions",
      "tables",
      "dictionary_context",
      "glossary_context",
      "definition_index",
      "citation_trust_exception",
      "has_search_pool",
      "has_search_context",
      "has_describe_table",
      "has_run_sql",
      "has_call_measure",
      "has_call_metrics",
      "has_call_calculation",
      "has_run_r",
      "has_instructions",
      "instructions"
    )
  )
})

test_that("Claude 5 model IDs are recognized across providers", {
  expect_true(is_claude_5_model("claude-sonnet-5"))
  expect_true(is_claude_5_model("anthropic/claude-opus-5"))
  expect_true(is_claude_5_model("us.anthropic.claude-fable-5"))
  expect_true(is_claude_5_model("databricks-claude-sonnet-5"))
  expect_false(is_claude_5_model("claude-sonnet-4-5"))
  expect_false(is_claude_5_model("gpt-5.4"))
  expect_false(is_claude_5_model(NULL))
})

test_that("instructions are not interpreted as prompt template expressions", {
  instructions <- "Use `{tables}` exactly as written."
  prompt <- test_agent(instructions = instructions)$get_system_prompt()

  expect_true(endsWith(prompt, instructions))
})

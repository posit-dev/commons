test_that("OpenAI citation smoke app constructs without an API request", {
  withr::local_envvar(
    c(
      OPENAI_API_KEY = "test-key",
      COMMONS_SMOKE_MODEL = "test-model"
    )
  )
  project_root <- normalizePath(test_path("..", ".."))
  app_path <- file.path(
    project_root,
    "sandbox",
    "commons-openai-citation-smoke",
    "app.R"
  )
  skip_if_not(
    file.exists(app_path),
    "sandbox/ isn't part of the installed package, so it's unavailable under R CMD check"
  )

  app_env <- new.env(parent = globalenv())
  app <- withr::with_dir(
    project_root,
    source(app_path, local = app_env)$value
  )

  expect_s3_class(app, "shiny.appobj")
  expect_match(
    app_env$greeting,
    paste(
      "For a baseline audit, explain why regeneration stands are excluded",
      "and identify the data field and allowed values used to distinguish",
      "them from established stands."
    ),
    fixed = TRUE
  )
  expect_match(
    app_env$greeting,
    "Which established stands lost canopy cover between 2021 and 2026?",
    fixed = TRUE
  )
})

test_that("the smoke app's own corpus can match its context-layer fixture", {
  skip_if_not_installed("shiny")
  withr::local_envvar(
    c(
      OPENAI_API_KEY = "test-key",
      COMMONS_SMOKE_MODEL = "test-model"
    )
  )
  project_root <- normalizePath(test_path("..", ".."))
  app_path <- file.path(
    project_root,
    "sandbox",
    "commons-openai-citation-smoke",
    "app.R"
  )
  skip_if_not(
    file.exists(app_path),
    "sandbox/ isn't part of the installed package, so it's unavailable under R CMD check"
  )

  app_env <- new.env(parent = globalenv())
  withr::with_dir(project_root, source(app_path, local = app_env))

  withr::with_dir(
    project_root,
    shiny::testServer(app_env$server, {
      expect_equal(
        match_citation(
          "Baseline canopy statistics include established stands only.",
          agent$citation_corpus()
        ),
        list(label = "documentation", kind = "prose")
      )
      expect_equal(
        match_citation(
          "Whether the stand is established or regeneration.",
          agent$citation_corpus()
        ),
        list(label = "stands table", kind = "schema")
      )
      expect_match(
        agent$get_system_prompt(),
        paste(
          "When exact trusted text supports a fallback answer, cite each",
          "paragraph or list item it supports using the citation instructions",
          "supplied by commons."
        ),
        fixed = TRUE
      )
      expect_match(
        agent$get_system_prompt(),
        paste(
          "For the exact question 'For a baseline audit, explain why",
          "regeneration stands are excluded and identify the data field and",
          "allowed values used to distinguish them from established stands.',",
          "search the reporting notes for the exclusion rationale and inspect",
          "the stands data documentation for the eligibility field and allowed",
          "values. Answer as two bullets and cite each bullet separately."
        ),
        fixed = TRUE
      )
      expect_match(
        agent$get_system_prompt(),
        paste(
          "For the exact question 'Which established stands lost canopy",
          "cover between 2021 and 2026?', use direct data analysis and",
          "deliberately omit a citation so the app demonstrates the",
          "Untrusted answer state."
        ),
        fixed = TRUE
      )
    })
  )
})

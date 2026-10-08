artifact_slug <- function(expr) {
  cnd <- tryCatch(expr, commons_artifact_invalid = function(cnd) cnd)
  if (inherits(cnd, "commons_artifact_invalid")) cnd$slug else NULL
}

test_that("edits match the shared cases", {
  spec <- shared_fixture("artifact-edit")
  expect_gt(length(spec$edits), 0)

  for (case in spec$edits) {
    run <- function() {
      apply_artifact_edit(
        case$source,
        case$old_string,
        case$new_string,
        isTRUE(case$replace_all)
      )
    }
    if (is.null(case$error)) {
      expect_identical(run(), case$expected, info = case$name)
    } else {
      expect_identical(artifact_slug(run()), case$error, info = case$name)
    }
  }
})

test_that("documents are validated as the shared cases say", {
  spec <- shared_fixture("artifact-edit")
  expect_gt(length(spec$documents), 0)
  expect_identical(artifact_allowed_keys, unlist(spec$allowed_keys))

  for (case in spec$documents) {
    if (is.null(case$error)) {
      doc <- parse_artifact_document(case$source)
      expect_identical(doc$frontmatter, case$expected$frontmatter, info = case$name)
      expect_identical(doc$body, case$expected$body, info = case$name)
    } else {
      expect_identical(
        artifact_slug(parse_artifact_document(case$source)),
        case$error,
        info = case$name
      )
    }
  }
})

test_that("trusted calls are normalized as the shared cases say", {
  spec <- shared_fixture("artifact-calls")
  expect_gt(length(spec$calls), 0)
  expect_identical(
    lapply(trusted_call_signatures, function(f) names(formals(f))),
    lapply(spec$methods, unlist)
  )

  for (case in spec$calls) {
    run <- function() normalize_trusted_call(case$method, case$arguments)
    if (is.null(case$error)) {
      expect_identical(run(), case$expected, info = case$name)
    } else {
      expect_identical(artifact_slug(run()), case$error, info = case$name)
    }
  }
})

test_that("trusted calls get files as the shared cases say", {
  spec <- shared_fixture("artifact-calls")
  expect_identical(ARTIFACT_MAX_CALLS, as.integer(spec$max_calls))

  for (case in spec$files) {
    run <- function() {
      calls <- list()
      for (x in case$calls) {
        found <- c(
          list(target = x$target),
          normalize_trusted_call(x$method, x$arguments)
        )
        calls <- register_trusted_call(calls, found)
      }
      unname(vapply(calls, `[[`, character(1), "file"))
    }
    if (is.null(case$error)) {
      expect_identical(run(), unlist(case$expected), info = case$name)
    } else {
      expect_identical(artifact_slug(run()), case$error, info = case$name)
    }
  }
})

test_that("trusted calls are found in R code with literal arguments", {
  found <- find_trusted_calls(paste(
    "#| label: totals",
    "revenue <- commons$metrics(\"net_revenue\", dimensions = c(\"region\"))",
    "nrow(commons$measure(\"orders\", arguments = list(n = -2)))",
    sep = "\n"
  ))
  expect_identical(
    vapply(found, `[[`, character(1), "text"),
    c(
      "commons$metrics(\"net_revenue\", dimensions = c(\"region\"))",
      "commons$measure(\"orders\", arguments = list(n = -2))"
    )
  )
  expect_identical(found[[1]]$target, "revenue")
  expect_null(found[[2]]$target)
  expect_identical(found[[2]]$call$arguments, list(n = -2))
  expect_length(find_trusted_calls("not R ("), 0)

  expect_identical(
    artifact_slug(find_trusted_calls("commons$measure(paste0(\"or\", \"ders\"))")),
    "non_literal_argument"
  )
  expect_identical(
    artifact_slug(find_trusted_calls("x <- \"orders\"\ncommons$measure(x)")),
    "non_literal_argument"
  )
  expect_identical(artifact_slug(find_trusted_calls("f <- commons$measure")), "reserved_name")
  expect_identical(artifact_slug(find_trusted_calls("commons$query(1)")), "unknown_method")
  expect_identical(
    artifact_slug(find_trusted_calls("commons$measure(\"a\", by = 1)")),
    "invalid_arguments"
  )
})

test_that("frontmatter reads booleans as YAML 1.2 does", {
  doc <- parse_artifact_document("---\ntitle: Top\nsubtitle: On\n---\nBody.\n")
  expect_identical(doc$frontmatter$subtitle, "On")
})

test_that("the saved document reads each trusted result from its file", {
  agent <- test_agent(data_sources = list(sales_db = definitions_source()))
  store <- agent$artifact_store()
  artifact <- artifact_ensure(store, "doc")
  run <- new_artifact_run(store, artifact)
  body <- paste0(
    "```{r}\nbig <- commons$metrics(\"big_revenue\", dimensions = \"region\")\n```\n\n",
    "EMEA had `r big$big_revenue[big$region == \"EMEA\"]`.\n"
  )
  for (unit in artifact_units(segment_artifact_body(body))) {
    artifact_run_prepare(run, unit)
  }

  dir <- withr::local_tempdir()
  doc <- parse_artifact_document(paste0("---\ntitle: Big\n---\n\n", body))
  write_artifact_dir(dir, doc, run$calls, artifact)

  expect_setequal(
    list.files(dir, recursive = TRUE),
    c("_quarto.yml", "report.qmd", "data/big.csv", "data/manifest.yaml")
  )
  qmd <- read_utf8(file.path(dir, "report.qmd"))
  expect_match(qmd, "big <- read.csv(\"data/big.csv\")", fixed = TRUE)
  expect_no_match(qmd, "commons", fixed = TRUE)
  big <- read.csv(file.path(dir, "data", "big.csv"))
  expect_equal(big$big_revenue[big$region == "EMEA"], 1950)

  manifest <- yaml::read_yaml(file.path(dir, "data", "manifest.yaml"))
  expect_named(manifest, "big.csv")
  expect_identical(manifest$big.csv$kind, "metrics")
  expect_identical(manifest$big.csv$call$metrics, "big_revenue")
  expect_match(manifest$big.csv$sql, "^SELECT")
  expect_match(manifest$big.csv$resolved, "^\\d{4}-\\d{2}-\\d{2}T")
})

test_that("a cell whose trusted call can't resolve shows the error", {
  store <- test_agent()$artifact_store()
  committed <- artifact_commit(
    store,
    "doc",
    "Doc",
    "---\ntitle: Doc\n---\n\n```{r}\nx <- commons$measure(\"missing\")\n```\n"
  )
  result <- wait_for_promise(committed$rendered)

  expect_match(result$errors, "Cell 1: `commons$measure()` failed", fixed = TRUE)
  expect_match(
    paste(result$html, collapse = ""),
    "<div class=\"commons-cell-error\">",
    fixed = TRUE
  )
  expect_length(artifact_get(store, "doc")$calls, 0)
})

test_that("documents split into prose blocks and cells as they arrive", {
  body <- paste0(
    "Intro with `r n`.\n\n::: {.callout-note}\nA note.\n\nStill the note.\n:::\n\n",
    "```{r}\n#| label: totals\nsum(x)\n```\n\nAfter."
  )
  pieces <- segment_artifact_body(body)
  expect_identical(
    vapply(pieces, `[[`, character(1), "kind"),
    c("prose", "prose", "cell", "prose")
  )
  expect_identical(pieces[[3]]$label, "totals")
  units <- artifact_units(pieces)
  expect_identical(
    vapply(units, `[[`, character(1), "text"),
    c("n", "```{r}\n#| label: totals\nsum(x)\n```")
  )

  partial <- segment_artifact_body("Done.\n\n```{r}\nsum(x)\n``", complete = FALSE)
  expect_false(partial[[2]]$complete)
  expect_length(artifact_units(partial), 0)
})

test_that("callouts keep their Markdown", {
  html <- markdown_fragment_html(convert_divs(
    "::: {.callout-warning title=\"Careful\"}\nSmall **samples**.\n:::"
  ))
  expect_match(html, "<div class=\"callout callout-warning\">", fixed = TRUE)
  expect_match(html, "<p class=\"callout-title\">Careful</p>", fixed = TRUE)
  expect_match(html, "<strong>samples</strong>", fixed = TRUE)
})

test_that("an edit that breaks the frontmatter makes no version", {
  store <- new_artifact_store(resolve_input = function(input) NULL)
  wait_for_promise(
    artifact_commit(store, "doc", "Doc", "---\ntitle: Doc\n---\nBody.\n")$rendered
  )

  expect_error(
    artifact_edit(store, "doc", "title: Doc", "title: Doc\nfilters: [x.lua]"),
    "may only set"
  )
  expect_length(artifact_get(store, "doc")$versions, 1)
  expect_error(artifact_edit(store, "other", "a", "b"), "no document")
})

test_that("restoring or clearing a conversation drops its artifacts", {
  agent <- test_agent()
  store <- agent$artifact_store()
  events <- list()
  store$listener <- function(event) events[[length(events) + 1L]] <<- event
  artifact_ensure(store, "doc")

  agent$set_turns(list())

  expect_length(ls(store$artifacts), 0)
  expect_identical(events[[length(events)]]$type, "reset")
})

# --- the live path ---------------------------------------------------------------

skip_if_no_sandbox <- function() {
  skip_on_cran()
  skip_if_not(
    identical(run_r_protection_mode(allow_guardrails = TRUE), "sandbox"),
    "This host can't sandbox document code."
  )
}

orders_agent <- function() {
  test_agent(
    semantic_layer = semantic_layer(
      measure(
        "orders",
        "All orders.",
        function() test_sales(),
        arguments = list()
      )
    )
  )
}

orders_document <- function(cell = "nrow(orders)") {
  paste0(
    "\n---\ntitle: Orders\n---\n\n",
    "```{r}\norders <- commons$measure(\"orders\")\n```\n\n",
    "There are `r ", cell, "` orders.\n\n",
    "```{r}\n#| label: by-region\ntable(orders$region)\nplot(orders$revenue)\n```\n"
  )
}

wait_until_ready <- function(store, id) {
  wait_for_promise(promises::promise(function(resolve, reject) {
    check <- function() {
      if (identical(store$artifacts[[id]]$status, "ready")) {
        resolve(TRUE)
      } else {
        later::later(check, 0.05)
      }
    }
    check()
  }))
}

test_that("a streamed document knits from its trusted calls as it arrives", {
  skip_if_no_sandbox()
  agent <- orders_agent()
  store <- agent$artifact_store()
  events <- list()
  store$listener <- function(event) events[[length(events) + 1L]] <<- event

  scanner <- citation_scanner(on_artifact = artifact_scan_handler(store))
  source <- paste0(
    "Here.\n<commons-artifact id=\"orders\" title=\"Orders\">",
    orders_document(),
    "</commons-artifact>\nDone."
  )
  starts <- seq(1, nchar(source), by = 20)
  out <- paste(
    vapply(substring(source, starts, starts + 19), scanner$feed, character(1)),
    collapse = ""
  )
  expect_match(out, "<commons-artifact-link artifact=\"orders\" version=\"1\"", fixed = TRUE)

  wait_until_ready(store, "orders")
  html <- paste(artifact_get(store, "orders")$html, collapse = "\n")
  expect_match(html, "There are 6 orders.", fixed = TRUE)
  expect_match(html, "<img src=\"data:image/png;base64,", fixed = TRUE)
  expect_match(html, "<details class=\"commons-code\">", fixed = TRUE)
  types <- vapply(events, `[[`, character(1), "type")
  expect_identical(types[[1]], "open")
  expect_true(all(c("pieces", "version", "status") %in% types))

  result <- wait_for_promise(
    artifact_edit(store, "orders", "nrow(orders)", "nrow(orders) - 1")
  )
  expect_identical(result@value, "Saved version 2 of `orders`.")
  expect_match(
    paste(artifact_get(store, "orders")$html, collapse = ""),
    "There are 5 orders.",
    fixed = TRUE
  )
})

test_that("a prose edit reuses every code result", {
  skip_if_no_sandbox()
  store <- orders_agent()$artifact_store()
  first <- artifact_commit(store, "orders", "Orders", orders_document())
  wait_for_promise(first$rendered)
  units <- artifact_get(store, "orders")$units

  wait_for_promise(artifact_edit(store, "orders", "There are", "We count"))

  artifact <- artifact_get(store, "orders")
  expect_identical(artifact$units, units)
  expect_match(paste(artifact$html, collapse = ""), "We count 6 orders.", fixed = TRUE)
  expect_equal(
    read.csv(file.path(artifact_latest_dir(artifact), "data", "orders.csv")),
    test_sales()
  )
})

test_that("errors stay in the document and are reported by cell", {
  skip_if_no_sandbox()
  store <- orders_agent()$artifact_store()
  wait_for_promise(
    artifact_commit(store, "orders", "Orders", orders_document())$rendered
  )

  result <- wait_for_promise(
    artifact_edit(store, "orders", "table(orders$region)", "stop('boom')")
  )
  expect_match(result@value, "Cell 2 (`by-region`): boom", fixed = TRUE)
  expect_match(
    paste(artifact_get(store, "orders")$html, collapse = ""),
    "<div class=\"commons-cell-error\">",
    fixed = TRUE
  )
})

test_that("a document's cells can't read the host's files", {
  skip_if_no_sandbox()
  store <- orders_agent()$artifact_store()
  secret <- withr::local_tempfile(tmpdir = path.expand("~"))
  writeLines("secret", secret)

  committed <- artifact_commit(
    store,
    "probe",
    "Probe",
    sprintf(
      "---\ntitle: Probe\n---\n\n```{r}\nreadLines(%s)\n```\n",
      deparse(secret)
    )
  )
  result <- wait_for_promise(committed$rendered)
  expect_length(result$errors, 1)
  expect_no_match(paste(result$html, collapse = ""), "secret\"")
})

test_that("outside Shiny, a turn's documents are knitted and reported", {
  skip_if_no_sandbox()
  agent <- orders_agent()
  turn <- ellmer::AssistantTurn(list(ellmer::ContentText(paste0(
    "Done.\n<commons-artifact id=\"orders\" title=\"Orders\">",
    orders_document(),
    "</commons-artifact>"
  ))))

  expect_message(
    save_turn_artifacts(agent$artifact_store(), turn),
    "report.html"
  )
  expect_match(
    paste(artifact_get(agent$artifact_store(), "orders")$html, collapse = ""),
    "There are 6 orders.",
    fixed = TRUE
  )
})

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

test_that("inputs are normalized as the shared cases say", {
  spec <- shared_fixture("artifact-inputs")
  expect_gt(length(spec$cases), 0)
  expect_identical(ARTIFACT_MAX_INPUTS, as.integer(spec$max_inputs))

  for (case in spec$cases) {
    if (is.null(case$error)) {
      expect_identical(
        normalize_artifact_inputs(case$inputs),
        case$expected,
        info = case$name
      )
    } else {
      expect_identical(
        artifact_slug(normalize_artifact_inputs(case$inputs)),
        case$error,
        info = case$name
      )
    }
  }
})

test_that("frontmatter reads booleans as YAML 1.2 does", {
  doc <- parse_artifact_document(paste0(
    "---\ntitle: Top\ncommons:\n  inputs:\n    top:\n      measure: top\n",
    "      arguments: {n: 3, y: on}\n---\nBody.\n"
  ))
  expect_identical(doc$inputs[[1]]$call$arguments, list(n = 3L, y = "on"))
})

test_that("the written document loads its inputs under commons' scaffold", {
  doc <- parse_artifact_document(paste0(
    "---\ntitle: Orders\ncommons:\n  inputs:\n    orders:\n",
    "      measure: orders\n---\n\nBody.\n"
  ))
  dir <- withr::local_tempdir()
  write_artifact_dir(dir, doc, list(orders = test_sales()))

  expect_setequal(
    list.files(dir, recursive = TRUE),
    c("_quarto.yml", "report.qmd", "data/orders.csv")
  )
  expect_equal(read.csv(file.path(dir, "data", "orders.csv")), test_sales())
  qmd <- read_utf8(file.path(dir, "report.qmd"))
  expect_no_match(qmd, "commons:", fixed = TRUE)
  expect_match(qmd, "`orders` <- read.csv(\"data/orders.csv\")", fixed = TRUE)
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
    identical(run_r_protection_mode(), "sandbox"),
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
    "\n---\ntitle: Orders\ncommons:\n  inputs:\n    orders:\n",
    "      measure: orders\n---\n\n",
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

test_that("a streamed document knits from its trusted inputs as it arrives", {
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
  expect_match(result@value, "Cell 1 (`by-region`): boom", fixed = TRUE)
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

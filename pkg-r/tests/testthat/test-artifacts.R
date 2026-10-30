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

test_that("a streamed source waits until it can tell whether frontmatter opens it", {
  for (prefix in c("", "\n", "-", "--", "---", "---\ntitle: A")) {
    expect_null(split_artifact_source(prefix, complete = FALSE), label = prefix)
  }
  expect_identical(
    split_artifact_source("# Sales", complete = FALSE),
    list(yaml = "", body = "# Sales")
  )
  expect_identical(split_artifact_source("---\ntitle: A\n---\nB")$body, "B")
})

test_that("a document without frontmatter takes the tag's title", {
  store <- new_artifact_store(resolve_input = function(method, args) NULL)
  committed <- artifact_commit(store, "doc", "Sales by region", "Just prose.\n")
  wait_for_promise(committed$rendered)

  artifact <- artifact_get(store, "doc")
  expect_identical(artifact$title, "Sales by region")
  expect_match(
    read_utf8(file.path(artifact_latest_dir(artifact), "report.qmd")),
    "^---\ntitle: Sales by region\n---\n\nJust prose."
  )
})

test_that("frontmatter reads booleans as YAML 1.2 does", {
  doc <- parse_artifact_document("---\ntitle: Top\nsubtitle: On\n---\nBody.\n")
  expect_identical(doc$frontmatter$subtitle, "On")
})


test_that("a document's commons answers with tables and values", {
  commons <- commons(
    data_sources = list(sales_db = definitions_source()),
    semantic_layer = semantic_layer(count_measure_tool())
  )

  big <- resolve_artifact_input(
    commons,
    "metrics",
    list(metrics = "big_revenue", dimensions = "region")
  )
  expect_s3_class(big, "data.frame")
  expect_equal(big$big_revenue[big$region == "EMEA"], 1950)
  expect_equal(
    resolve_artifact_input(
      commons,
      "measure",
      list(name = "order_count", arguments = list(region = "EMEA"))
    ),
    3
  )
  expect_equal(
    resolve_artifact_input(
      commons,
      "run_sql",
      list(query = "SELECT COUNT(*) AS n FROM sales WHERE {{emea}}")
    )$n,
    sum(test_sales()$region == "EMEA")
  )
})

test_that("a document's commons refuses other methods, objects, and plots", {
  skip_if_not_installed("ggplot2")
  commons <- commons(
    data_sources = list(sales_db = test_source()),
    semantic_layer = semantic_layer(measure(
      "revenue_plot",
      "A plot of revenue.",
      function() ggplot2::ggplot(test_sales(), ggplot2::aes(revenue)),
      arguments = list()
    ))
  )

  expect_error(
    resolve_artifact_input(commons, "describe", list(table = "sales")),
    "only"
  )
  expect_error(
    resolve_artifact_input(commons, "run_sql", list(query = quote(x))),
    "strings, numbers"
  )
  expect_error(
    resolve_artifact_input(commons, "measure", list(name = "revenue_plot")),
    "neither a table nor a value"
  )
  expect_error(
    resolve_artifact_input(commons, "run_sql", list(query = "DELETE FROM sales"))
  )
})

test_that("the saved document keeps its commons calls", {
  dir <- withr::local_tempdir()
  body <- "```{r}\nbig <- commons$metrics(\"big_revenue\")\n```\n"
  write_artifact_dir(dir, parse_artifact_document(paste0("---\ntitle: Big\n---\n\n", body)))

  expect_setequal(list.files(dir, recursive = TRUE), c("_quarto.yml", "report.qmd"))
  expect_match(
    read_utf8(file.path(dir, "report.qmd")),
    "big <- commons$metrics(\"big_revenue\")",
    fixed = TRUE
  )
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
  store <- new_artifact_store(resolve_input = function(method, args) NULL)
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

test_that("a streamed document knits from its commons calls as it arrives", {
  skip_if_no_sandbox()
  agent <- orders_agent()
  store <- agent$artifact_store()
  events <- list()
  store$listener <- function(event) events[[length(events) + 1L]] <<- event

  scanner <- citation_scanner(on_artifact = artifact_scan_handler(store))
  source <- paste0(
    "Here.\n<artifact id=\"orders\" title=\"Orders\">",
    orders_document(),
    "</artifact>\nDone."
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
  expect_match(result@value, "Cell 2 (`by-region`): boom", fixed = TRUE)
  expect_match(
    paste(artifact_get(store, "orders")$html, collapse = ""),
    "<div class=\"commons-cell-error\">",
    fixed = TRUE
  )
})

test_that("a cell whose commons call fails shows the error", {
  skip_if_no_sandbox()
  store <- orders_agent()$artifact_store()
  committed <- artifact_commit(
    store,
    "doc",
    "Doc",
    paste0(
      "---\ntitle: Doc\n---\n\n",
      "```{r}\nx <- commons$measure(\"missing\")\n```\n\n",
      "```{r}\ncommons$describe(\"sales\")\n```\n\n",
      "```{r}\nnrow(commons$measure(\"orders\"))\n```\n"
    )
  )
  result <- wait_for_promise(committed$rendered)

  expect_length(result$errors, 2)
  expect_match(result$errors[[1]], "Cell 1: `commons$measure()` failed", fixed = TRUE)
  expect_match(paste(result$html, collapse = ""), "[1] 6", fixed = TRUE)
})

test_that("cells after one that times out still run", {
  skip_if_no_sandbox()
  withr::local_options(commons.run_r_timeout = 1)
  store <- orders_agent()$artifact_store()
  committed <- artifact_commit(
    store,
    "slow",
    "Slow",
    "---\ntitle: Slow\n---\n\n```{r}\nSys.sleep(30)\n```\n\n```{r}\n1 + 41\n```\n"
  )
  result <- wait_for_promise(committed$rendered)

  expect_length(result$errors, 1)
  expect_match(result$errors, "^Cell 1: ")
  expect_match(paste(result$html, collapse = ""), "[1] 42", fixed = TRUE)
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

test_that("embedding a figure respects the document's sandbox", {
  skip_if_no_sandbox()
  store <- orders_agent()$artifact_store()
  secret <- withr::local_tempfile(tmpdir = path.expand("~"))
  writeLines("figure-sandbox-probe", secret)
  source <- paste0(
    "---\ntitle: Probe\n---\n\n",
    "```{r, echo=FALSE, results='asis'}\n",
    "path <- file.path(as.environment('commons:knit')$figs, 'probe.png')\n",
    "file.symlink(", deparse(secret), ", path)\n",
    "cat(paste0('![](', path, ')'))\n",
    "```\n"
  )

  result <- wait_for_promise(
    artifact_commit(store, "probe", "Probe", source)$rendered
  )

  expect_length(result$errors, 1)
  encoded <- jsonlite::base64_enc(charToRaw("figure-sandbox-probe\n"))
  expect_match(
    paste(result$html, collapse = ""), "class=\"commons-cell-error\"", fixed = TRUE
  )
  expect_false(grepl(encoded, paste(result$html, collapse = ""), fixed = TRUE))
  report <- read_utf8(file.path(
    artifact_latest_dir(artifact_get(store, "probe")), "report.html"
  ))
  expect_false(grepl(encoded, report, fixed = TRUE))
})

test_that("the first chat saves its documents and later chats save only new turns", {
  skip_if_no_sandbox()
  agent <- orders_agent()
  source <- paste0(
    "<artifact id=\"orders\" title=\"Orders\">",
    orders_document(),
    "</artifact>"
  )
  # Supply a response while exercising ellmer's parsing and chat.
  local_mocked_bindings(
    chat_perform = function(...) {
      httr2::response(
        status_code = 200,
        headers = list("content-type" = "application/json"),
        body = charToRaw(jsonlite::toJSON(list(
          content = list(list(type = "text", text = source)),
          stop_reason = "end_turn",
          usage = list(input_tokens = 0, output_tokens = 0)
        ), auto_unbox = TRUE))
      )
    },
    .package = "ellmer"
  )

  expect_length(agent$get_turns(), 0)
  for (version in 1:2) {
    expect_message(agent$chat("Write a report.", echo = "none"), "report.html")
    artifact <- artifact_get(agent$artifact_store(), "orders")
    expect_length(artifact$versions, version)
    expect_match(
      paste(artifact$html, collapse = ""),
      "There are 6 orders.",
      fixed = TRUE
    )
  }
})

test_that("clearing a closed stream cancels its render and its callbacks", {
  skip_if_no_sandbox()
  agent <- orders_agent()
  store <- agent$artifact_store()
  events <- list()
  store$listener <- function(event) events[[length(events) + 1L]] <<- event
  scanner <- citation_scanner(on_artifact = artifact_scan_handler(store))
  source <- "---\ntitle: Old\n---\n\n```{r}\nSys.sleep(2)\nstop('old render')\n```\n"
  scanner$feed(paste0("<artifact id=\"doc\" title=\"Old\">\n", source))
  run <- store$streams$doc
  scanner$feed("</artifact>")
  while (is.null(run$worker)) {
    later::run_now(0.01)
  }
  worker <- run$worker$rs
  expect_length(ls(store$streams), 0)

  agent$set_turns(list())
  expect_true(run$cancelled)
  expect_false(worker$is_alive())
  expect_length(ls(store$runs), 0)
  events <- list()
  scanner <- citation_scanner(on_artifact = artifact_scan_handler(store))
  scanner$feed(paste0(
    "<artifact id=\"doc\" title=\"New\">\n",
    "---\ntitle: New\n---\n\nNew document.\n</artifact>"
  ))
  wait_until_ready(store, "doc")
  wait_for_promise(run$tail)
  # Drain the finish and reminder callbacks chained after the last unit.
  later::run_now(0.1)

  pieces <- Filter(function(event) identical(event$type, "pieces"), events)
  html <- paste(vapply(
    pieces[[length(pieces)]]$pieces, `[[`, character(1), "html"
  ), collapse = "")
  expect_match(html, "New document.", fixed = TRUE)
  expect_identical(artifact_get(store, "doc")$title, "New")
  expect_length(store$reminders, 0)
  expect_length(ls(store$runs), 0)
  expect_match(
    read_utf8(file.path(
      artifact_latest_dir(artifact_get(store, "doc")), "report.qmd"
    )),
    "title: New",
    fixed = TRUE
  )
})

test_that("clearing a conversation also cancels an edit's render", {
  store <- new_artifact_store(resolve_input = function(method, args) NULL)
  wait_for_promise(artifact_commit(
    store, "doc", "Doc", "---\ntitle: Doc\n---\n\nOriginal.\n"
  )$rendered)
  edited <- artifact_edit(store, "doc", "Original.", "Revised.")
  run <- store$runs[[ls(store$runs)[[1]]]]
  events <- list()
  store$listener <- function(event) events[[length(events) + 1L]] <<- event

  artifact_store_reset(store)
  result <- wait_for_promise(edited)

  expect_true(run$cancelled)
  expect_length(ls(store$runs), 0)
  expect_null(artifact_get(store, "doc"))
  expect_identical(vapply(events, `[[`, character(1), "type"), "reset")
  expect_false(dir.exists(file.path(store$root, "doc", "v2")))
  expect_identical(
    result@value, "The conversation was cleared before the edit finished."
  )
})

test_that("outside Shiny, a call's documents are knitted and reported", {
  skip_if_no_sandbox()
  agent <- orders_agent()
  turns <- list(
    ellmer::AssistantTurn(list(ellmer::ContentText(paste0(
      "<artifact id=\"orders\" title=\"Orders\">",
      orders_document(),
      "</artifact>"
    )))),
    ellmer::UserTurn(list(ellmer::ContentText("A tool result."))),
    ellmer::AssistantTurn(list(ellmer::ContentText("Done.")))
  )

  expect_message(
    save_turn_artifacts(agent$artifact_store(), turns),
    "report.html"
  )
  expect_match(
    paste(artifact_get(agent$artifact_store(), "orders")$html, collapse = ""),
    "There are 6 orders.",
    fixed = TRUE
  )
})

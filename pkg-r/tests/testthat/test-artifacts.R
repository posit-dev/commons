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
  expect_match(out, "<commons-artifact-link artifact=\"orders\"", fixed = TRUE)

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

test_that("answering a commons call doesn't write through a planted symlink", {
  skip_if_no_sandbox()
  store <- orders_agent()$artifact_store()
  target <- withr::local_tempfile(tmpdir = path.expand("~"))
  writeLines("untouched", target)
  source <- paste0(
    "---\ntitle: Probe\n---\n\n",
    "```{r}\n",
    "file.symlink(", deparse(target), ", file.path('.commons', ",
    "paste0(Sys.getpid(), '-1.rds.partial')))\n",
    "nrow(commons$measure('orders'))\n",
    "```\n"
  )

  result <- wait_for_promise(
    artifact_commit(store, "probe", "Probe", source)$rendered
  )

  expect_length(result$errors, 0)
  expect_match(paste(result$html, collapse = ""), "[1] 6", fixed = TRUE)
  expect_identical(readLines(target), "untouched")
})

test_that("a saved document can't navigate or submit on its own", {
  html <- markdown_fragment_html(paste0(
    "<META http-equiv=\"refresh\" content=\"0;url=https://example.com\">\n\n",
    "<base href=\"https://example.com/\">\n\n",
    "<form action=\"https://example.com\"><button>Send</button></form>\n"
  ))
  page <- artifact_document_html("Probe", html)

  expect_no_match(page, "<(meta http-equiv=\"refresh\"|base|form)", ignore.case = TRUE)
  expect_match(page, "<button>Send</button>", fixed = TRUE)
  expect_match(page, "form-action 'none'; base-uri 'none'", fixed = TRUE)
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

test_that("a plot directly after a cell's code shows as an image", {
  skip_if_no_sandbox()
  store <- orders_agent()$artifact_store()
  source <- "---\ntitle: Plot\n---\n\n```{r}\nplot(1:3)\n```\n"

  result <- wait_for_promise(
    artifact_commit(store, "plot", "Plot", source)$rendered
  )

  html <- paste(result$html, collapse = "")
  expect_match(html, "<img src=\"data:image/png;base64,", fixed = TRUE)
  expect_false(grepl("![", html, fixed = TRUE))
})

test_that("a document's first plot becomes its link's thumbnail", {
  skip_if_no_sandbox()
  store <- orders_agent()$artifact_store()
  events <- list()
  store$listener <- function(event) events[[length(events) + 1L]] <<- event
  source <- "---\ntitle: Plot\n---\n\nText.\n\n```{r}\n1 + 1\n```\n\n```{r}\nplot(1:3)\n```\n"

  wait_for_promise(artifact_commit(store, "plot", "Plot", source)$rendered)

  thumbnail <- artifact_get(store, "plot")$thumbnail
  expect_match(thumbnail, "^data:image/png;base64,[A-Za-z0-9+/=]+$")
  sent <- Filter(function(event) identical(event$type, "thumbnail"), events)
  expect_identical(sent[[length(sent)]]$src, thumbnail)
  expect_identical(artifact_select_event(artifact_get(store, "plot"))$thumbnail, thumbnail)

  wait_for_promise(artifact_edit(store, "plot", "plot(1:3)", "2 + 2"))
  expect_null(artifact_get(store, "plot")$thumbnail)
})

test_that("only an embedded PNG drawn by a cell is a thumbnail", {
  png <- "data:image/png;base64,iVBORw0KGgo="
  img <- function(src) sprintf("<p><img src=\"%s\" alt=\"\" /></p>", src)
  units <- list(
    list(kind = "markdown", html = img(png)),
    list(kind = "cell", html = img("https://example.com/plot.png")),
    list(kind = "cell", html = img("data:image/svg+xml;base64,PHN2Zz4=")),
    list(kind = "cell", status = "pending")
  )

  expect_null(artifact_thumbnail(units))
  expect_identical(
    artifact_thumbnail(c(units, list(list(kind = "cell", html = img(png))))),
    png
  )
})

test_that("a clone of the agent doesn't clear the original's documents", {
  agent <- orders_agent()
  store <- agent$artifact_store()
  events <- character()
  store$listener <- function(event) events <<- c(events, event$type)
  artifact_store_restore(
    store,
    list(orders = list(title = "Orders", sources = list(orders_document())))
  )

  clone <- agent$clone()
  clone$set_turns(list())

  expect_identical(agent$artifact_store(), store)
  expect_equal(names(artifact_store_values(store)), "orders")
  expect_length(events, 0)
  expect_false(identical(clone$artifact_store(), store))
  expect_length(artifact_store_values(clone$artifact_store()), 0)

  # Before the clone resets, it starts with the original's documents.
  expect_equal(names(artifact_store_values(agent$clone()$artifact_store())), "orders")
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

# --- restored conversations ------------------------------------------------------

prose_store <- function() {
  store <- new_artifact_store(resolve_input = function(method, args) NULL)
  wait_for_promise(artifact_commit(store, "doc", "Doc", "First.\n")$rendered)
  wait_for_promise(artifact_edit(store, "doc", "First.", "Second."))
  store
}

test_that("saved turns show each document tag as a link to the document", {
  store <- prose_store()
  text <- "Here.\n<artifact id=\"doc\" title=\"Doc\">First.\n</artifact>\nDone."
  turns <- list(
    ellmer::UserTurn(list(ellmer::ContentText("Write it."))),
    ellmer::AssistantTurn(list(
      ellmer::ContentText(text),
      ellmer::ContentText("No markup here.")
    ))
  )

  projected <- project_turns_display(turns, 1L, list(), store)
  contents <- projected[[2]]@contents
  expect_true(S7::S7_inherits(contents[[1]], ContentProjectedText))
  expect_identical(contents[[1]]@text, text)
  expect_match(shinychat::contents_shinychat(contents[[1]]), "<commons-artifact-link artifact=\"doc\"", fixed = TRUE)
  expect_no_match(shinychat::contents_shinychat(contents[[1]]), "<artifact ", fixed = TRUE)
  expect_identical(class(contents[[2]])[[1]], "ellmer::ContentText")
  expect_identical(projected[[1]], turns[[1]])

  replayed <- ellmer::contents_replay(ellmer::contents_record(projected[[2]]))
  expect_identical(replayed@contents[[1]]@display, contents[[1]]@display)
})

test_that("a restored document renders when it's first needed", {
  values <- artifact_store_values(prose_store())
  expect_identical(values$doc$title, "Doc")

  store <- new_artifact_store(resolve_input = function(method, args) NULL)
  artifact_store_restore(store, jsonlite::fromJSON(jsonlite::toJSON(values)))
  expect_length(ls(store$artifacts), 0)
  expect_identical(artifact_store_values(store), values)

  artifact <- artifact_get(store, "doc")
  wait_until_ready(store, "doc")
  expect_length(artifact$versions, 2)
  expect_match(paste(artifact$html, collapse = ""), "Second.", fixed = TRUE)
  expect_true(file.exists(file.path(artifact_latest_dir(artifact), "report.qmd")))
})

test_that("a restored document can be edited or rewritten before it's opened", {
  values <- artifact_store_values(prose_store())

  edited <- new_artifact_store(resolve_input = function(method, args) NULL)
  artifact_store_restore(edited, values)
  result <- wait_for_promise(artifact_edit(edited, "doc", "Second.", "Third."))
  expect_identical(result@value, "Saved version 3 of `doc`.")

  rewritten <- new_artifact_store(resolve_input = function(method, args) NULL)
  artifact_store_restore(rewritten, values)
  committed <- artifact_commit(rewritten, "doc", "Doc", "Fresh.\n")
  wait_for_promise(committed$rendered)
  expect_identical(committed$version, 3L)
  expect_length(ls(rewritten$pending), 0)
})

test_that("a streamed reply's turn keeps its text and shows the link", {
  chunks <- c(
    "I wrote it.\n\n<artifact id=\"doc\" title=\"Doc\">Just ",
    "prose.\n</artifact>\n\nDone."
  )
  raw <- paste0(chunks, collapse = "")
  local_mocked_bindings(
    chat_perform = function(...) {
      coro::async_generator(function() {
        for (chunk in chunks) yield(list(text = chunk))
        coro::exhausted()
      })()
    },
    stream_merge_chunks = function(provider, result, chunk) chunk,
    stream_content_with_turns = function(provider, event, completion = NULL, turns = list()) {
      list(ellmer::ContentText(event$text))
    },
    value_finish_reason = function(provider, result) "stop",
    value_turn_with_turns = function(provider, model, result, has_type = FALSE, turns = list()) {
      ellmer::AssistantTurn(list(ellmer::ContentText(raw)), tokens = c(0, 0, 0), cost = 0)
    },
    .package = "ellmer"
  )
  agent <- test_agent()

  wait_for_promise(coro::async_collect(agent$stream_async("Write it.")))

  turns <- agent$get_turns()
  content <- turns[[length(turns)]]@contents[[1]]
  expect_true(S7::S7_inherits(content, ContentProjectedText))
  expect_identical(content@text, raw)
  expect_match(content@display, "<commons-artifact-link artifact=\"doc\"", fixed = TRUE)
  expect_length(artifact_get(agent$artifact_store(), "doc")$versions, 1)
})

# --- hidden follow-ups -----------------------------------------------------------

# Answers each request with the next of `responses`, repeating the last, while
# exercising ellmer's streaming and turn handling. `on_reply(n)` runs as the
# nth reply finishes. Returns a count of requests.
local_scripted_stream <- function(responses, on_reply = NULL, env = parent.frame()) {
  calls <- 0L
  current <- function() responses[[min(calls, length(responses))]]
  local_mocked_bindings(
    chat_perform = function(...) {
      calls <<- calls + 1L
      text <- current()
      coro::async_generator(function() {
        yield(list(text = text))
        coro::exhausted()
      })()
    },
    stream_merge_chunks = function(provider, result, chunk) chunk,
    stream_content_with_turns = function(provider, event, completion = NULL, turns = list()) {
      list(ellmer::ContentText(event$text))
    },
    value_finish_reason = function(provider, result) "stop",
    value_turn_with_turns = function(provider, model, result, has_type = FALSE, turns = list()) {
      if (!is.null(on_reply)) on_reply(calls)
      ellmer::AssistantTurn(list(ellmer::ContentText(current())), tokens = c(0, 0, 0), cost = 0)
    },
    .package = "ellmer",
    .env = env
  )
  function() calls
}

stream_text <- function(agent, input) {
  chunks <- wait_for_promise(coro::async_collect(
    agent$stream_async(input, stream = "content")
  ))
  texts <- Filter(function(x) S7::S7_inherits(x, ellmer::ContentText), chunks)
  paste(vapply(texts, function(x) x@text, character(1)), collapse = "")
}

test_that("a document that fails to render is fixed in the same response", {
  skip_if_no_sandbox()
  calls <- local_scripted_stream(list(
    "Here.\n<artifact id=\"doc\" title=\"Doc\">\n```{r}\nstop('boom')\n```\n</artifact>",
    "Fixed it."
  ))
  agent <- orders_agent()

  text <- stream_text(agent, "Write it.")

  expect_identical(calls(), 2L)
  expect_match(text, "Here.", fixed = TRUE)
  expect_match(text, "\n\nFixed it.", fixed = TRUE)
  turns <- agent$get_turns()
  expect_length(turns, 4)
  hidden <- turns[[3]]@contents
  expect_true(all(vapply(hidden, S7::S7_inherits, logical(1), class = ContentTurnReminder)))
  expect_match(
    hidden[[length(hidden)]]@text,
    "^<system-instruction>Version 1 of the document `doc` ran with errors"
  )
  messages <- shinychat::contents_shinychat(agent)
  expect_identical(
    vapply(messages, `[[`, character(1), "role"),
    c("user", "assistant")
  )
  expect_length(agent$artifact_store()$reminders, 0)
})

rejected_document <- "<artifact id=\"doc\" title=\"Doc\">\n---\nengine: knitr\n---\n\nHi.\n</artifact>"

test_that("a response stops following up after the limit", {
  calls <- local_scripted_stream(list(rejected_document))
  agent <- test_agent()

  stream_text(agent, "Write it.")

  expect_identical(calls(), 1L + artifact_followup_limit)
  # What the last attempt left waits for the user's next message.
  expect_length(agent$artifact_store()$reminders, 1)
})

test_that("a cancelled response doesn't follow up", {
  controller <- ellmer::stream_controller()
  calls <- local_scripted_stream(
    list(rejected_document, "Fixed it."),
    on_reply = function(n) controller$cancel()
  )
  agent <- test_agent()

  wait_for_promise(coro::async_collect(
    agent$stream_async("Write it.", controller = controller)
  ))

  expect_identical(calls(), 1L)
})

test_that("a hidden follow-up doesn't count as a new user message", {
  turn <- ellmer::UserTurn(list(ContentTurnReminder(text = "<system-instruction>Fix it.</system-instruction>")))
  expect_false(turn_has_user_message(turn))
  expect_true(is_internal_turn(turn))
})

test_that("outside Shiny, a call follows up too and returns the fix", {
  calls <- 0L
  local_mocked_bindings(
    chat_perform = function(...) {
      calls <<- calls + 1L
      text <- if (calls == 1L) rejected_document else "Fixed it."
      httr2::response(
        status_code = 200,
        headers = list("content-type" = "application/json"),
        body = charToRaw(jsonlite::toJSON(list(
          content = list(list(type = "text", text = text)),
          stop_reason = "end_turn",
          usage = list(input_tokens = 0, output_tokens = 0)
        ), auto_unbox = TRUE))
      )
    },
    .package = "ellmer"
  )
  agent <- test_agent()

  expect_warning(
    result <- agent$chat("Write it.", echo = "none"),
    "was not saved"
  )

  expect_identical(calls, 2L)
  expect_identical(as.character(result), "Fixed it.")
  expect_length(agent$get_turns(), 4)
  expect_length(agent$artifact_store()$reminders, 0)
})

test_that("an earlier version still rendering doesn't overwrite the view", {
  skip_if_no_sandbox()
  store <- orders_agent()$artifact_store()
  wait_for_promise(artifact_commit(store, "doc", "Doc", "```{r}\n'one'\n```\n")$rendered)
  events <- list()
  store$listener <- function(event) events[[length(events) + 1L]] <<- event

  # As when a reply makes two edits at once: the slower version finishes last.
  slow <- artifact_edit(store, "doc", "'one'", "Sys.sleep(1.5); 'two'")
  fast <- artifact_edit(store, "doc", "Sys.sleep(1.5); 'two'", "'three'")
  wait_for_promise(promises::promise_all(slow, fast))

  pieces <- list()
  for (event in events) {
    if (identical(event$type, "pieces")) {
      for (piece in event$pieces) pieces[[piece$index + 1L]] <- piece$html
      length(pieces) <- event$count
    }
  }
  shown <- paste(unlist(pieces), collapse = "")
  expect_match(shown, "three", fixed = TRUE)
  expect_no_match(shown, "two", fixed = TRUE)
  statuses <- Filter(function(event) identical(event$type, "status"), events)
  expect_identical(statuses[[length(statuses)]]$status, "ready")
})

test_that("an earlier version finishing during a rewrite leaves the view to it", {
  skip_if_no_sandbox()
  store <- orders_agent()$artifact_store()
  scanner <- citation_scanner(on_artifact = artifact_scan_handler(store))
  scanner$feed(paste0(
    "<artifact id=\"doc\" title=\"Doc\">\n",
    "```{r}\nSys.sleep(1); 'one'\n```\n</artifact>\n"
  ))
  first <- store$settling[[1]]
  scanner$feed("<artifact id=\"doc\" title=\"Doc\">\nRewriting")
  events <- list()
  store$listener <- function(event) events[[length(events) + 1L]] <<- event

  wait_for_promise(first)

  types <- vapply(events, `[[`, character(1), "type")
  expect_false(any(c("status", "thumbnail", "pieces") %in% types))
  expect_match(paste(store$artifacts$doc$html, collapse = ""), "one", fixed = TRUE)

  scanner$feed(" the document.\n</artifact>")
  wait_for_promise(artifact_store_settled(store))
  expect_match(paste(store$artifacts$doc$html, collapse = ""), "Rewriting", fixed = TRUE)
  statuses <- Filter(function(event) identical(event$type, "status"), events)
  expect_identical(statuses[[length(statuses)]]$status, "ready")
})

test_that("reopening a document that failed before rendering shows why", {
  artifact <- new.env(parent = emptyenv())
  artifact$id <- "doc"
  artifact$title <- "Doc"
  artifact$status <- "ready"
  artifact$html <- character()
  artifact$errors <- "The worker didn't start."

  expect_identical(artifact_select_event(artifact)$error, "The worker didn't start.")

  artifact$html <- "<p>Shown.</p>"
  expect_identical(artifact_select_event(artifact)$error, "")
})

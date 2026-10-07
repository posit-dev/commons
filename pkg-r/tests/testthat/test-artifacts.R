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

test_that("the written document carries its inputs and commons' scaffold", {
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
  expect_match(qmd, "title=\"Trusted inputs\"", fixed = TRUE)
  expect_match(qmd, "`data/orders.csv`: measure", fixed = TRUE)
  expect_match(qmd, "`orders` <- read.csv(\"data/orders.csv\")", fixed = TRUE)
})

test_that("an edit that breaks the frontmatter makes no version", {
  store <- new_artifact_store(resolve_input = function(input) NULL)
  local_mocked_bindings(
    artifact_render_queued = function(store, dir) {
      promises::promise_resolve(list(html = "<p>ok</p>"))
    }
  )
  artifact_commit(store, "doc", "Doc", "---\ntitle: Doc\n---\nBody.\n")

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
  assign("doc", new.env(), envir = store$artifacts)

  agent$set_turns(list())

  expect_length(ls(store$artifacts), 0)
  expect_identical(events[[length(events)]]$type, "reset")
})

# --- the live path ---------------------------------------------------------------

skip_if_no_quarto <- function() {
  skip_on_cran()
  skip_if(is.null(quarto_binary()), "Quarto is not installed.")
  skip_if_not_installed("rmarkdown")
  skip_if_not(
    identical(run_r_protection_mode(), "sandbox"),
    "This host can't sandbox the render."
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
    "There are `r ", cell, "` orders.\n"
  )
}

test_that("a streamed document renders from its trusted inputs", {
  skip_if_no_quarto()
  agent <- orders_agent()
  store <- agent$artifact_store()
  events <- list()
  store$listener <- function(event) events[[length(events) + 1L]] <<- event

  scanner <- citation_scanner(on_artifact = artifact_scan_handler(store))
  out <- scanner$feed(paste0(
    "Here.\n<commons-artifact id=\"orders\" title=\"Orders\">",
    orders_document(),
    "</commons-artifact>\nDone."
  ))
  expect_match(out, "<commons-artifact-link artifact=\"orders\" version=\"1\"", fixed = TRUE)

  wait_for_promise(store$tail)
  html <- artifact_get(store, "orders")$html
  expect_match(html, "There are 6 orders.", fixed = TRUE)
  expect_match(html, "Trusted inputs", fixed = TRUE)
  types <- vapply(events, `[[`, character(1), "type")
  expect_identical(types[c(1, length(types))], c("open", "rendered"))
  expect_true(all(c("delta", "version") %in% types))

  result <- wait_for_promise(
    artifact_edit(store, "orders", "nrow(orders)", "nrow(orders) - 1")
  )
  expect_match(result@value, "Saved and rendered version 2", fixed = TRUE)
  expect_match(artifact_get(store, "orders")$html, "There are 5 orders.", fixed = TRUE)

  zip <- withr::local_tempfile(fileext = ".zip")
  artifact_zip(store, "orders", zip)
  expect_setequal(
    utils::unzip(zip, list = TRUE)$Name,
    c("_quarto.yml", "report.qmd", "report.html", "data/orders.csv")
  )
})

test_that("a failed render keeps the last good version and is reported", {
  skip_if_no_quarto()
  agent <- orders_agent()
  store <- agent$artifact_store()

  first <- artifact_commit(store, "orders", "Orders", orders_document())
  expect_null(wait_for_promise(first$rendered)$error)

  result <- wait_for_promise(
    artifact_edit(store, "orders", "nrow(orders)", "stop('boom')")
  )
  expect_match(result@value, "failed to render", fixed = TRUE)
  expect_match(result@value, "boom", fixed = TRUE)
  expect_match(result@value, "still sees version 1", fixed = TRUE)
  expect_identical(artifact_get(store, "orders")$html_version, 1L)
})

test_that("a document's cells can't reach the network or the host's files", {
  skip_if_no_quarto()
  agent <- orders_agent()
  store <- agent$artifact_store()
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
  expect_false(is.null(result$error))
  expect_no_match(result$error, "^secret$")
})

test_that("context_layer indexes files and finds relevant chunks", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(
    c(
      "# Revenue",
      "Revenue excludes tax unless stated otherwise.",
      "",
      "# Discounts",
      "Discounts are applied before tax."
    ),
    path
  )

  layer <- context_layer(files = path)
  hits <- context_search(layer, "what does revenue mean")

  expect_gte(length(hits), 1)
  expect_match(hits[[1]], "tax")
})

test_that("context_search returns empty when nothing matches or store is empty", {
  expect_length(context_search(context_layer(), "anything"), 0)

  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# A", "apples"), path)
  expect_length(context_search(context_layer(files = path), "zzzzz"), 0)
})

test_that("context_layer strips YAML frontmatter before indexing", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(
    c(
      "---",
      "provenance: https://github.com/org/app/blob/abc1234/R/server.R#L1-L9",
      "---",
      "# Revenue",
      "Revenue excludes tax unless stated otherwise."
    ),
    path
  )

  layer <- context_layer(files = path)

  expect_match(context_search(layer, "revenue")[[1]], "tax")
  expect_length(context_search(layer, "abc1234"), 0)
})

test_that("context_layer leaves a body thematic break intact", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(
    c(
      "# Intro",
      "Revenue excludes tax.",
      "",
      "---",
      "",
      "# Details",
      "Discounts are applied before tax."
    ),
    path
  )

  layer <- context_layer(files = path)

  expect_match(context_search(layer, "discounts")[[1]], "before tax")
})

test_that("strip_frontmatter leaves a file without frontmatter unchanged", {
  md <- "# Revenue\nRevenue excludes tax."
  expect_equal(strip_frontmatter(md), md)
})

test_that("context_layer skips a frontmatter-only file", {
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("---", "provenance: some-source", "---"), path)

  layer <- context_layer(files = path)
  expect_length(context_search(layer, "provenance"), 0)
})

test_that("the context store persists on disk and is shared across layers", {
  withr::local_options(commons.context_cache = withr::local_tempdir())
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# Revenue", "", "Revenue means booked revenue."), path)

  layer1 <- context_layer(files = path)
  store_path <- context_store_path(layer1$docs)
  expect_false(file.exists(store_path))

  expect_match(context_search(layer1, "revenue")[[1]], "booked")
  expect_true(file.exists(store_path))

  # A distinct layer with the same docs opens the same on-disk store
  layer2 <- context_layer(files = path)
  expect_identical(context_store_path(layer2$docs), store_path)
  expect_match(context_search(layer2, "revenue")[[1]], "booked")

  # Different docs key a different store
  expect_false(identical(context_store_path("other docs"), store_path))
})

test_that("commons.context_cache = FALSE builds the store in memory", {
  withr::local_options(commons.context_cache = FALSE)
  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# Revenue", "", "Revenue means booked revenue."), path)

  layer <- context_layer(files = path)
  expect_match(context_search(layer, "revenue")[[1]], "booked")
  expect_identical(
    DBI::dbGetInfo(context_layer_state(layer)$store@con)$dbname,
    ":memory:"
  )
})

test_that("an unwritable cache dir warns once and falls back to a tempdir", {
  # A file where the cache dir should be makes dir.create() fail.
  blocker <- withr::local_tempfile()
  writeLines("occupied", blocker)
  withr::local_options(commons.context_cache = file.path(blocker, "cache"))

  context_cache_state$warned <- NULL
  context_cache_state$fallback_dir <- NULL

  path <- withr::local_tempfile(fileext = ".md")
  writeLines(c("# Revenue", "", "Revenue means booked revenue."), path)
  layer <- context_layer(files = path)

  expect_warning(
    expect_match(context_search(layer, "revenue")[[1]], "booked"),
    "Falling back to a per-session temporary directory"
  )
  # The fallback is stable within the session and warns only once
  expect_no_warning(context_cache_dir_safe())
  expect_identical(context_cache_dir_safe(), context_cache_state$fallback_dir)
})

test_that("prune_context_cache() removes old stores and keeps young ones", {
  dir <- withr::local_tempdir()
  old <- file.path(dir, "old.duckdb")
  young <- file.path(dir, "young.duckdb")
  file.create(old, young)
  Sys.setFileTime(old, Sys.time() - 40 * 24 * 60 * 60)

  context_cache_state$n_builds <- 0
  context_cache_state$last_prune <- NULL
  prune_context_cache(dir)

  expect_false(file.exists(old))
  expect_true(file.exists(young))
})

test_that("prune_context_cache() is throttled across builds", {
  dir <- withr::local_tempdir()
  stale <- file.path(dir, "stale.duckdb")
  file.create(stale)
  Sys.setFileTime(stale, Sys.time() - 40 * 24 * 60 * 60)

  # A prune just happened, and the build count isn't at a multiple of 20
  context_cache_state$n_builds <- 1
  context_cache_state$last_prune <- Sys.time()
  prune_context_cache(dir)
  expect_true(file.exists(stale))

  # Twenty builds since the throttle reset forces a prune
  context_cache_state$n_builds <- 19
  prune_context_cache(dir)
  expect_false(file.exists(stale))
})

test_that("cache root prefers the option, then env vars", {
  withr::local_options(commons.context_cache = NULL)
  withr::local_envvar(
    COMMONS_CONTEXT_CACHE = NA,
    CONNECT_CONTENT_DATA_DIR = NA,
    SHINY_SERVER_VERSION = NA
  )
  expect_identical(
    context_cache_dir(),
    tools::R_user_dir("commons", "cache")
  )

  withr::local_envvar(CONNECT_CONTENT_DATA_DIR = "/connect/data")
  expect_identical(context_cache_dir(), "/connect/data")

  withr::local_envvar(COMMONS_CONTEXT_CACHE = "/explicit/cache")
  expect_identical(context_cache_dir(), "/explicit/cache")

  withr::local_options(commons.context_cache = "/option/cache")
  expect_identical(context_cache_dir(), "/option/cache")
})

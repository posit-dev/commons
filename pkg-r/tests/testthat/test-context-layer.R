test_that("strip_frontmatter matches the shared cases", {
  cases <- shared_fixture("context_layer")$strip_frontmatter$cases

  for (case in cases) {
    expect_identical(
      strip_frontmatter(case$input),
      case$expected,
      info = case$name
    )
  }
})

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
  store_path <- context_store_path(context_layer_state(layer1)$docs)
  expect_false(file.exists(store_path))

  expect_match(context_search(layer1, "revenue")[[1]], "booked")
  expect_true(file.exists(store_path))


  layer2 <- context_layer(files = path)
  expect_identical(
    context_store_path(context_layer_state(layer2)$docs),
    store_path
  )
  expect_match(context_search(layer2, "revenue")[[1]], "booked")


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

  expect_no_warning(context_cache_dir_safe())
  expect_identical(context_cache_dir_safe(), context_cache_state$fallback_dir)
})

test_that("prune_context_cache() is throttled across builds", {
  dir <- withr::local_tempdir()
  stale <- file.path(dir, "stale.duckdb")
  writeLines(strrep("x", 1000), stale)


  context_cache_state$n_builds <- 1
  context_cache_state$last_prune <- Sys.time()
  prune_context_cache(dir, max_size = 1)
  expect_true(file.exists(stale))


  context_cache_state$n_builds <- 19
  prune_context_cache(dir, max_size = 1)
  expect_false(file.exists(stale))
})

test_that("prune_context_cache() evicts least-recently-used stores over the size cap", {
  dir <- withr::local_tempdir()
  oldest <- file.path(dir, "oldest.duckdb")
  middle <- file.path(dir, "middle.duckdb")
  newest <- file.path(dir, "newest.duckdb")
  for (f in c(oldest, middle, newest)) {
    writeLines(strrep("x", 1000), f)
  }
  now <- Sys.time()
  Sys.setFileTime(oldest, now - 300)
  Sys.setFileTime(middle, now - 200)
  Sys.setFileTime(newest, now - 100)

  context_cache_state$n_builds <- 0
  context_cache_state$last_prune <- NULL

  cap <- 2 * file.size(newest)
  prune_context_cache(dir, max_size = cap)

  expect_false(file.exists(oldest))
  expect_true(file.exists(middle))
  expect_true(file.exists(newest))
})

test_that("an unwritable cache dir surfaces only the once-per-session warning", {
  skip_on_os("windows") # Sys.chmod() read-only bits aren't enforced there
  skip_if(.Platform$OS.type == "unix" && Sys.info()[["user"]] == "root")

  # The cache dir itself is unwritable, so the probe's file.create() fails
  readonly <- withr::local_tempdir()
  withr::defer(Sys.chmod(readonly, mode = "0755"))
  Sys.chmod(readonly, mode = "0555")
  withr::local_options(commons.context_cache = readonly)

  context_cache_state$warned <- NULL
  context_cache_state$fallback_dir <- NULL


  warnings <- character()
  withCallingHandlers(
    context_cache_dir_safe(),
    warning = function(w) {
      warnings <<- c(warnings, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )
  expect_length(warnings, 1)
  expect_match(warnings, "Falling back to a per-session temporary directory")

  warnings <- character()
  withCallingHandlers(
    context_cache_dir_safe(),
    warning = function(w) {
      warnings <<- c(warnings, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )
  expect_length(warnings, 0)
})

test_that("prune_context_cache() tolerates stores vanishing mid-prune", {
  dir <- withr::local_tempdir()
  store <- file.path(dir, "store.duckdb")
  writeLines(strrep("x", 1000), store)

  context_cache_state$n_builds <- 0
  context_cache_state$last_prune <- NULL

  # A broken symlink is listed but stats as NA, like a store a concurrent
  # pruner deleted mid-prune
  skip_on_os("windows") # symlinks need elevated privileges there
  ghost <- file.path(dir, "ghost.duckdb")
  file.symlink(file.path(dir, "no-such-target"), ghost)

  context_cache_state$warned_size <- NULL
  expect_no_warning(
    expect_no_error(prune_context_cache(dir, max_size = file.size(store)))
  )
  expect_true(file.exists(store))
})

test_that("prune_context_cache() keeps a single store larger than the cap", {
  dir <- withr::local_tempdir()
  big <- file.path(dir, "big.duckdb")
  writeLines(strrep("x", 10000), big)

  context_cache_state$n_builds <- 0
  context_cache_state$last_prune <- NULL
  context_cache_state$warned_size <- NULL

  expect_warning(
    prune_context_cache(dir, max_size = 1, protect = big),
    "exceeds its size cap"
  )
  expect_true(file.exists(big))


  context_cache_state$n_builds <- 0
  context_cache_state$last_prune <- NULL
  expect_no_warning(
    prune_context_cache(dir, max_size = 1, protect = big)
  )
  expect_true(file.exists(big))
})

test_that("prune_context_cache() reaps stale .build-* temp files only", {
  dir <- withr::local_tempdir()
  old <- file.path(dir, ".build-old")
  fresh <- file.path(dir, ".build-fresh")
  store <- file.path(dir, "store.duckdb")
  for (f in c(old, fresh, store)) {
    writeLines("x", f)
  }
  Sys.setFileTime(old, Sys.time() - 25 * 60 * 60)

  context_cache_state$n_builds <- 0
  context_cache_state$last_prune <- NULL
  prune_context_cache(dir)

  expect_false(file.exists(old))
  expect_true(file.exists(fresh))
  expect_true(file.exists(store))
})

test_that("context_store() warns and rebuilds when the cached store won't open", {
  layer <- new_context_layer(c("Some context about widgets."))
  path <- context_store_path(context_layer_state(layer)$docs)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  # Stand in for a store unlinked or corrupted between file.exists() and
  # connect (e.g. by a concurrent pruner)
  writeLines("not a duckdb file", path)

  expect_warning(
    store <- context_store(layer),
    "rebuilding"
  )
  expect_identical(store, context_layer_state(layer)$store)
  expect_equal(
    context_search(layer, "widgets"),
    "Some context about widgets."
  )
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

test_that("the context_cache option must be a path or FALSE", {
  withr::local_options(commons.context_cache = TRUE)
  expect_error(context_cache_dir(), "must be a path")
})

test_that("COMMONS_CONTEXT_CACHE can disable the cache", {
  withr::local_options(commons.context_cache = NULL)
  withr::local_envvar(COMMONS_CONTEXT_CACHE = "FALSE")
  expect_false(context_cache_enabled())

  withr::local_envvar(CONNECT_CONTENT_DATA_DIR = "/connect/data")
  expect_identical(context_cache_dir(), "/connect/data")
})

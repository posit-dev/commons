# These tests exercise the real worker: they need an installed commons (the
# worker loads the package from the library, not from load_all()).

# Every run_r call arms later timers that outlive it. Run each test on its own
# loop so the leftovers die with it: shiny::testServer() reads outputs
# through shiny:::wait_for_it(), which spins until later::loop_empty(), so a
# timer left on the global loop stalls other files' testServer() blocks for its
# full delay (#267). later::with_loop() and later::with_temp_loop() are the
# exported analogs, but both wrap an expression rather than a scope, so this
# calls the internal they use to switch loops.
local_temp_loop <- function(env = parent.frame()) {
  old <- later::current_loop()
  loop <- later::create_loop(parent = NULL)
  later:::setCurrentRegistryId(loop$id)
  withr::defer(
    {
      later:::setCurrentRegistryId(old$id)
      later::destroy_loop(loop)
    },
    envir = env
  )
  invisible(loop)
}

# Only meaningful when nothing else has queued work on the global loop.
global_loop_clean <- later::loop_empty(later::global_loop())

local_worker <- function(env = parent.frame()) {
  worker <- new_r_worker()
  withr::defer(worker_close(worker), envir = env)
  worker
}

local_guardrail_worker <- function(network = "none", env = parent.frame()) {
  worker <- new_r_worker(network, "guardrails")
  withr::defer(worker_close(worker), envir = env)
  worker
}

worker_read_lines <- function(worker, path) {
  worker$rs$run(function(path) readLines(path), args = list(path = path))
}

test_that("run_r executes code against stored handles", {
  local_temp_loop()
  worker <- local_worker()
  store <- new_handle_store()
  register_handle(store, test_sales())

  res <- sync_promise(run_r_tool(worker, store, "sum(r1$revenue)"))

  expect_s7_class(res, ellmer::ContentToolResult)
  expect_match(res@value, "5650")
  expect_equal(res@extra$commons_tag, "B")
  expect_false(res@extra$display$open)
  expect_match(
    res@extra$display$html,
    '<pre class="commons-run-r-code"><code class="language-r">',
    fixed = TRUE
  )
  expect_match(
    res@extra$display$html,
    '<span class="hl kwd">sum</span>',
    fixed = TRUE
  )
  expect_match(
    res@extra$display$html,
    '<span class="hl com">#&gt; [1] 5650</span>',
    fixed = TRUE
  )
  expect_match(res@extra$display$html, "#&gt; [1] 5650", fixed = TRUE)
  expect_no_match(res@extra$display$html, "<details", fixed = TRUE)
  expect_no_match(
    res@extra$display$html,
    "<summary>Details</summary>",
    fixed = TRUE
  )
})

test_that("run_r session state persists across calls, and handles sync lazily", {
  local_temp_loop()
  worker <- local_worker()
  store <- new_handle_store()

  sync_promise(run_r_tool(worker, store, "x <- 40 + 2"))
  register_handle(store, test_sales())
  res <- sync_promise(run_r_tool(worker, store, "x + nrow(r1)"))

  expect_match(res@value, "48")
})

test_that("worker entry points stay outside the model environment", {
  local_temp_loop()
  worker <- local_guardrail_worker()
  store <- new_handle_store()
  outside <- withr::local_tempfile(tmpdir = dirname(tempdir()))
  writeLines("secret", outside)
  replacement <- sprintf(
    paste0(
      "worker_run_code <- function(...) ",
      "list(segments = list(list(type = 'text', text = readLines(%s))))"
    ),
    encodeString(outside, quote = "\"")
  )

  sync_promise(run_r_tool(worker, store, replacement))
  res <- sync_promise(run_r_tool(worker, store, "1 + 1"))

  expect_match(res@value, "[1] 2", fixed = TRUE)
  expect_no_match(res@value, "secret", fixed = TRUE)
})

test_that("run_r prepends a worker-local package library", {
  local_temp_loop()
  worker <- local_guardrail_worker()
  worker_ensure(worker)

  paths <- worker$rs$run(function() {
    list(libraries = .libPaths(), bit64 = find.package("bit64"))
  })

  expect_equal(basename(paths$libraries[[1]]), "library")
  expect_true(dir.exists(paths$libraries[[1]]))
  expect_false(startsWith(paths$bit64, paths$libraries[[1]]))
})

test_that("run_r loads integer64 methods for stored handles", {
  local_temp_loop()
  skip_if_not_installed("bit64")
  worker <- local_worker()
  store <- new_handle_store()
  register_handle(
    store,
    data.frame(n = bit64::as.integer64(c(326, 338)))
  )

  res <- sync_promise(run_r_tool(worker, store, "as.numeric(r1$n)"))

  expect_match(res@value, "[1] 326 338", fixed = TRUE)
})

test_that("run_r returns plots as images and opens the display", {
  local_temp_loop()
  worker <- local_worker()
  store <- new_handle_store()
  register_handle(store, test_sales())

  res <- sync_promise(run_r_tool(worker, store, "plot(r1$revenue)"))

  images <- Filter(
    \(x) S7::S7_inherits(x, ellmer::ContentImageInline),
    res@value
  )
  expect_length(images, 1)
  notes <- Filter(
    \(x) S7::S7_inherits(x, ellmer::ContentText),
    res@value
  )
  expect_true(any(vapply(
    notes,
    \(x) grepl("This plot is already visible to the user", x@text, fixed = TRUE),
    logical(1)
  )))
  expect_identical(res@extra$display$open, TRUE)
  expect_match(res@extra$display$html, "data:image/png;base64,")
  expect_match(res@extra$display$html, "commons-run-r-details")
  expect_match(res@extra$display$html, "commons-run-r-code", fixed = TRUE)
  expect_match(res@extra$display$html, "<summary>Details</summary>", fixed = TRUE)
})

test_that("run_r collapses code and output above plots", {
  local_temp_loop()
  worker <- local_worker()
  store <- new_handle_store()

  res <- sync_promise(run_r_tool(
    worker,
    store,
    "cat('private text\\n'); message('private message'); warning('private warning'); plot(1)"
  ))

  expect_match(res@value[[1]]@text, "private text")
  expect_match(res@value[[1]]@text, "private message")
  expect_match(res@value[[1]]@text, "private warning")
  expect_match(
    res@extra$display$html,
    '<details class="commons-run-r-details"><summary>Details</summary>',
    fixed = TRUE
  )
  expect_match(res@extra$display$html, "#&gt; private text", fixed = TRUE)
  expect_match(res@extra$display$html, "#&gt; private message", fixed = TRUE)
  expect_match(res@extra$display$html, "#&gt; private warning", fixed = TRUE)
  expect_match(res@extra$display$html, "data:image/png;base64,")
  expect_lt(
    as.integer(regexpr("commons-run-r-details", res@extra$display$html)),
    as.integer(regexpr("data:image/png;base64,", res@extra$display$html))
  )
})

test_that("run_r preloads measure sources for reading, comments included", {
  local_temp_loop()
  worker <- local_worker()
  store <- new_handle_store()
  fn_sources <- c(order_count = "function() {\n  # count every order\n  6L\n}")

  res <- sync_promise(run_r_tool(worker, store, "order_count", fn_sources))
  expect_match(res@value, "# count every order", fixed = TRUE)

  called <- sync_promise(run_r_tool(worker, store, "order_count()", fn_sources))
  expect_match(called@value, "6")
})

test_that("run_r delivers the citation request when no fallback tool has", {
  local_temp_loop()
  agent <- test_agent()
  withr::defer(worker_close(agent$.__enclos_env__$private$worker))
  run_r <- agent_tool(agent, "run_r")

  res <- sync_promise(run_r("1 + 1"))

  expect_match(res@value, "[1] 2", fixed = TRUE)
  expect_match(res@value, "<commons-citation>", fixed = TRUE)
})

test_that("run_r surfaces errors from model code without failing the tool", {
  local_temp_loop()
  worker <- local_worker()
  store <- new_handle_store()

  res <- sync_promise(run_r_tool(worker, store, "stop('boom')"))

  expect_s7_class(res, ellmer::ContentToolResult)
  expect_match(res@value, "Error: boom")
  expect_false(res@extra$display$open)
  expect_match(res@extra$display$html, "#&gt; boom", fixed = TRUE)
  expect_match(res@extra$display$html, "commons-run-r-code", fixed = TRUE)
  expect_no_match(res@extra$display$html, "<details", fixed = TRUE)
})

test_that("run_r displays code directly when it produces no output", {
  local_temp_loop()
  worker <- local_worker()
  store <- new_handle_store()

  res <- sync_promise(run_r_tool(worker, store, "x <- 1"))

  expect_match(res@value, "produced no output", fixed = TRUE)
  expect_false(res@extra$display$open)
  expect_match(
    res@extra$display$html,
    '<span class="hl def">x</span>',
    fixed = TRUE
  )
  expect_match(
    res@extra$display$html,
    '<span class="hl num">1</span>',
    fixed = TRUE
  )
  expect_match(res@extra$display$html, "commons-run-r-code", fixed = TRUE)
  expect_no_match(res@extra$display$html, "#&gt;", fixed = TRUE)
  expect_no_match(res@extra$display$html, "<details", fixed = TRUE)
})

test_that("run_r highlights malformed code without exposing HTML", {
  local_temp_loop()
  expect_no_warning(
    html <- run_r_html("x <- '<unsafe>' +", list())
  )

  expect_match(html, "'&lt;unsafe&gt;'", fixed = TRUE)
  expect_no_match(html, "<unsafe>", fixed = TRUE)
})

test_that("run_r displays worker failures directly and escapes their HTML", {
  local_temp_loop()
  res <- run_r_result("x <- '<unsafe>'", list(failure = "worker <broke>"))

  expect_match(res@value, "Error: worker <broke>", fixed = TRUE)
  expect_equal(res@extra$display$title, "Analyzed data")
  expect_false(res@extra$display$open)
  expect_match(res@extra$display$html, "'&lt;unsafe&gt;'", fixed = TRUE)
  expect_match(res@extra$display$html, "#&gt; worker &lt;broke&gt;", fixed = TRUE)
  expect_match(res@extra$display$html, "commons-run-r-code", fixed = TRUE)
  expect_no_match(res@extra$display$html, "<details", fixed = TRUE)
})

test_that("the worker cannot see parent-only environment variables", {
  local_temp_loop()
  withr::local_envvar(COMMONS_TEST_SECRET = "s3cret")
  worker <- local_worker()
  store <- new_handle_store()

  res <- sync_promise(run_r_tool(
    worker,
    store,
    "nzchar(Sys.getenv('COMMONS_TEST_SECRET'))"
  ))

  expect_match(res@value, "FALSE")
})

test_that("run_r interrupts code exceeding the time limit, keeping the session", {
  local_temp_loop()
  withr::local_options(commons.run_r_timeout = 2)
  worker <- local_worker()
  store <- new_handle_store()

  sync_promise(run_r_tool(worker, store, "x <- 1"))
  res <- sync_promise(run_r_tool(worker, store, "Sys.sleep(30)"))
  expect_match(res@value, "time limit")

  after <- sync_promise(run_r_tool(worker, store, "x"))
  expect_match(after@value, "1")
})

test_that("a crashed worker reports the crash and respawns on the next call", {
  local_temp_loop()
  worker <- local_worker()
  store <- new_handle_store()
  register_handle(store, test_sales())

  sync_promise(run_r_tool(worker, store, "nrow(r1)"))
  res <- sync_promise(run_r_tool(worker, store, "tools::pskill(Sys.getpid())"))
  expect_match(res@value, "crashed")

  # handles resync into the fresh session
  after <- sync_promise(run_r_tool(worker, store, "nrow(r1)"))
  expect_match(after@value, "6")
})

test_that("concurrent run_r calls take turns on the worker", {
  local_temp_loop()
  worker <- local_worker()
  store <- new_handle_store()

  p1 <- run_r_tool(worker, store, "y <- 10")
  p2 <- run_r_tool(worker, store, "y * 2")

  res <- sync_promise(promises::promise_all(p1, p2))
  expect_match(res[[2]]@value, "20")
})

test_that("guardrails allow computation and worker-local files", {
  local_temp_loop()
  worker <- local_guardrail_worker()
  store <- new_handle_store()
  worker_ensure(worker)

  expect_false(worker$rs$run(function() {
    exists(".commons_guardrails", envir = globalenv(), inherits = FALSE)
  }))
  expect_true(worker$rs$run(function() {
    ".commons_guardrails" %in%
      ls(as.environment("commons:guardrails"), all.names = TRUE)
  }))

  res <- sync_promise(run_r_tool(
    worker,
    store,
    paste(
      "copying <- readLines(file.path(R.home(), 'COPYING'), n = 1)",
      "writeLines(copying, 'copying.txt')",
      "parse(text = '1 + 1')",
      "list.files(pattern = 'copying')",
      "c(sum(1:10), length(readLines('copying.txt')))",
      sep = "; "
    )
  ))

  expect_match(res@value, "55")
  expect_match(res@value, "1")
})

test_that("guardrails deny external filesystem access and subprocesses", {
  local_temp_loop()
  worker <- local_guardrail_worker()
  store <- new_handle_store()
  outside <- withr::local_tempfile(tmpdir = dirname(tempdir()))
  writeLines("secret", outside)

  read <- sync_promise(run_r_tool(
    worker,
    store,
    sprintf("readLines(%s)", encodeString(outside, quote = "\""))
  ))
  write <- sync_promise(run_r_tool(
    worker,
    store,
    sprintf("writeLines('changed', %s)", encodeString(outside, quote = "\""))
  ))
  probe <- sync_promise(run_r_tool(
    worker,
    store,
    sprintf("file.exists(%s)", encodeString(outside, quote = "\""))
  ))
  subprocess <- sync_promise(run_r_tool(
    worker,
    store,
    "system2('R', '--version')"
  ))
  download <- sync_promise(run_r_tool(
    worker,
    store,
    sprintf(
      "download.file('https://example.com', %s)",
      encodeString(outside, quote = "\"")
    )
  ))

  expect_match(read@value, "denied read access", fixed = TRUE)
  expect_match(write@value, "denied write access", fixed = TRUE)
  expect_match(probe@value, "denied read access", fixed = TRUE)
  expect_match(subprocess@value, "denied subprocess creation", fixed = TRUE)
  expect_match(download@value, "denied network access", fixed = TRUE)
  expect_identical(readLines(outside), "secret")
})

test_that("guardrails resolve symlinks and nonexistent descendants", {
  local_temp_loop()
  worker <- local_guardrail_worker()
  store <- new_handle_store()
  worker_ensure(worker)
  work_dir <- worker$rs$run(getwd)
  outside <- withr::local_tempdir(tmpdir = dirname(tempdir()))
  writeLines("secret", file.path(outside, "secret.txt"))
  linked <- file.symlink(outside, file.path(work_dir, "outside-link"))
  skip_if_not(linked, "cannot create symlinks")

  read <- sync_promise(run_r_tool(
    worker,
    store,
    "readLines('outside-link/secret.txt')"
  ))
  write <- sync_promise(run_r_tool(
    worker,
    store,
    "writeLines('changed', 'outside-link/new/nested.txt')"
  ))

  expect_match(read@value, "denied read access", fixed = TRUE)
  expect_match(write@value, "denied write access", fixed = TRUE)
  expect_false(file.exists(file.path(outside, "new", "nested.txt")))
})

test_that("guardrails follow the configured network policy", {
  local_temp_loop()
  restricted <- local_guardrail_worker()
  full <- local_guardrail_worker("full")
  store <- new_handle_store()

  denied <- sync_promise(run_r_tool(
    restricted,
    store,
    "con <- serverSocket(0); close(con)"
  ))
  allowed <- sync_promise(run_r_tool(
    full,
    store,
    "con <- serverSocket(0); close(con); TRUE"
  ))
  outside <- withr::local_tempfile(tmpdir = dirname(tempdir()))
  local_url <- paste0("file://", file.path(R.home(), "COPYING"))
  local_file <- sync_promise(run_r_tool(
    full,
    store,
    sprintf(
      "download.file(%s, %s)",
      encodeString(local_url, quote = "\""),
      encodeString(outside, quote = "\"")
    )
  ))
  external_destination <- sync_promise(run_r_tool(
    full,
    store,
    sprintf(
      "download.file('https://example.com', %s)",
      encodeString(outside, quote = "\"")
    )
  ))

  expect_match(denied@value, "denied network access", fixed = TRUE)
  expect_match(allowed@value, "TRUE", fixed = TRUE)
  expect_match(local_file@value, "denied read access", fixed = TRUE)
  expect_match(
    external_destination@value,
    "denied write access",
    fixed = TRUE
  )
})

test_that("guardrails restore bindings after success and model errors", {
  local_temp_loop()
  worker <- local_guardrail_worker()
  store <- new_handle_store()
  outside <- withr::local_tempfile(tmpdir = dirname(tempdir()))
  writeLines("available after restoration", outside)

  sync_promise(run_r_tool(worker, store, "sum(1:10)"))
  expect_identical(
    worker_read_lines(worker, outside),
    "available after restoration"
  )
  expect_identical(
    worker$rs$run(
      function(url, path) {
        suppressWarnings(download.file(url, path, quiet = TRUE))
        readLines(path)
      },
      args = list(url = paste0("file://", outside), path = tempfile())
    ),
    "available after restoration"
  )

  sync_promise(run_r_tool(worker, store, "stop('boom')"))
  expect_identical(
    worker_read_lines(worker, outside),
    "available after restoration"
  )
})

test_that("run_r's timers stay on the loop the call ran on", {
  local_temp_loop()
  worker <- local_worker()
  store <- new_handle_store()
  register_handle(store, test_sales())

  sync_promise(run_r_tool(worker, store, "sum(r1$revenue)"))

  # The leftovers belong to this loop, so they are discarded with it rather
  # than stalling other files' testServer() blocks (#267).
  expect_false(later::loop_empty())
})

test_that("these tests leave the global later loop as they found it", {
  skip_if_not(global_loop_clean, "global later loop was already busy")
  expect_true(later::loop_empty(later::global_loop()))
})

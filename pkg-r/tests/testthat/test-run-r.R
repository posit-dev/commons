# These tests exercise the real worker: they need an installed commons (the
# worker loads the package from the library, not from load_all()).

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
  expect_match(res@extra$display$html, "#&gt; [1] 5650", fixed = TRUE)
  expect_no_match(res@extra$display$html, "<details", fixed = TRUE)
  expect_no_match(
    res@extra$display$html,
    "<summary>Details</summary>",
    fixed = TRUE
  )
})

test_that("run_r session state persists across calls, and handles sync lazily", {
  worker <- local_worker()
  store <- new_handle_store()

  sync_promise(run_r_tool(worker, store, "x <- 40 + 2"))
  register_handle(store, test_sales())
  res <- sync_promise(run_r_tool(worker, store, "x + nrow(r1)"))

  expect_match(res@value, "48")
})

test_that("run_r loads integer64 methods for stored handles", {
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
  worker <- local_worker()
  store <- new_handle_store()
  fn_sources <- c(order_count = "function() {\n  # count every order\n  6L\n}")

  res <- sync_promise(run_r_tool(worker, store, "order_count", fn_sources))
  expect_match(res@value, "# count every order", fixed = TRUE)

  called <- sync_promise(run_r_tool(worker, store, "order_count()", fn_sources))
  expect_match(called@value, "6")
})

test_that("run_r delivers the citation request when no fallback tool has", {
  agent <- test_agent()
  withr::defer(worker_close(agent$.__enclos_env__$private$worker))
  run_r <- agent_tool(agent, "run_r")

  res <- sync_promise(run_r("1 + 1"))

  expect_match(res@value, "[1] 2", fixed = TRUE)
  expect_match(res@value, "<commons-citation>", fixed = TRUE)
})

test_that("run_r surfaces errors from model code without failing the tool", {
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
  worker <- local_worker()
  store <- new_handle_store()

  res <- sync_promise(run_r_tool(worker, store, "x <- 1"))

  expect_match(res@value, "produced no output", fixed = TRUE)
  expect_false(res@extra$display$open)
  expect_match(res@extra$display$html, "x &lt;- 1", fixed = TRUE)
  expect_match(res@extra$display$html, "commons-run-r-code", fixed = TRUE)
  expect_no_match(res@extra$display$html, "#&gt;", fixed = TRUE)
  expect_no_match(res@extra$display$html, "<details", fixed = TRUE)
})

test_that("run_r displays worker failures directly and escapes their HTML", {
  res <- run_r_result("x <- '<unsafe>'", list(failure = "worker <broke>"))

  expect_match(res@value, "Error: worker <broke>", fixed = TRUE)
  expect_false(res@extra$display$open)
  expect_match(res@extra$display$html, "&#39;&lt;unsafe&gt;&#39;", fixed = TRUE)
  expect_match(res@extra$display$html, "#&gt; worker &lt;broke&gt;", fixed = TRUE)
  expect_match(res@extra$display$html, "commons-run-r-code", fixed = TRUE)
  expect_no_match(res@extra$display$html, "<details", fixed = TRUE)
})

test_that("the worker cannot see parent-only environment variables", {
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
  worker <- local_worker()
  store <- new_handle_store()

  p1 <- run_r_tool(worker, store, "y <- 10")
  p2 <- run_r_tool(worker, store, "y * 2")

  res <- sync_promise(promises::promise_all(p1, p2))
  expect_match(res[[2]]@value, "20")
})

test_that("guardrails allow computation and worker-local files", {
  worker <- local_guardrail_worker()
  store <- new_handle_store()

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

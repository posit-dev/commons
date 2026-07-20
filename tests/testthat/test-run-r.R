# These tests exercise the real worker: they need an installed commons (the
# worker loads the package from the library, not from load_all()).

local_worker <- function(env = parent.frame()) {
  worker <- new_r_worker()
  withr::defer(worker_close(worker), envir = env)
  worker
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
})

test_that("run_r session state persists across calls, and handles sync lazily", {
  worker <- local_worker()
  store <- new_handle_store()

  sync_promise(run_r_tool(worker, store, "x <- 40 + 2"))
  register_handle(store, test_sales())
  res <- sync_promise(run_r_tool(worker, store, "x + nrow(r1)"))

  expect_match(res@value, "48")
})

test_that("run_r returns plots as images and opens the display", {
  worker <- local_worker()
  store <- new_handle_store()
  register_handle(store, test_sales())

  res <- sync_promise(run_r_tool(worker, store, "plot(r1$revenue)"))

  expect_true(any(vapply(
    res@value,
    function(x) S7::S7_inherits(x, ellmer::ContentImageInline),
    logical(1)
  )))
  expect_true(res@extra$display$open)
  expect_match(res@extra$display$html, "data:image/png;base64,")
  expect_match(res@extra$display$html, "commons-run-r-code")
})

test_that("run_r surfaces errors from model code without failing the tool", {
  worker <- local_worker()
  store <- new_handle_store()

  res <- sync_promise(run_r_tool(worker, store, "stop('boom')"))

  expect_s7_class(res, ellmer::ContentToolResult)
  expect_match(res@value, "Error: boom")
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

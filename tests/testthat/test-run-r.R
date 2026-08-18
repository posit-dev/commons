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
  withr::local_options(
    commons.plot_aspect_ratio = "2:1",
    commons.plot_size = 600L
  )
  worker <- local_worker()
  store <- new_handle_store()
  register_handle(store, test_sales())

  res <- sync_promise(run_r_tool(worker, store, "plot(r1$revenue)"))

  images <- Filter(
    \(x) S7::S7_inherits(x, ellmer::ContentImageInline),
    res@value
  )
  expect_length(images, 1)
  expect_equal(
    png_dimensions_from_base64(images[[1]]@data),
    c(width = 600, height = 300)
  )
  expect_identical(res@extra$display$open, TRUE)
  expect_match(res@extra$display$html, "data:image/png;base64,")
  expect_match(res@extra$display$html, "commons-run-r-details")
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

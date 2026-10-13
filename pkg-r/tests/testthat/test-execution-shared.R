# What the model reads back from run_r, and the worker's time limits and
# failure messages, are cross-language contracts: the cases live in
# tests/shared/execution-repl.json and tests/shared/worker-lifecycle.json, and
# the Python suite runs the same ones. Do not restate a case here; add it to
# the fixture.
#
# Every case runs in a real worker, so these need an installed commons (the
# worker loads the package from the library, not from load_all()).

for_r <- function(value) {
  if (is.list(value)) value$r else value
}

shared_worker <- function(env = parent.frame()) {
  withr::local_options(commons.allow_unsafe_fallback = TRUE)
  worker <- new_r_worker(protection = run_r_protection_mode())
  withr::defer(worker_close(worker), envir = env)
  worker
}

tool_output <- function(worker, code) {
  sync_promise(run_r_tool(worker, new_handle_store(), code))@value
}

test_that("run_r output follows the shared fixture", {
  spec <- shared_fixture("execution-repl")$cases
  expect_gt(length(spec$cases), 0)

  for (case in spec$cases) {
    worker <- shared_worker()
    for (call in case$calls) {
      output <- tool_output(worker, call$r)
    }

    if (!is.null(case$output)) {
      expected <- for_r(case$output)
      if (identical(expected, "$no_output")) {
        expected <- spec$no_output
      }
      expect_identical(output, expected, label = case$name)
    } else {
      lines <- strsplit(output, "\n", fixed = TRUE)[[1]]
      expect_identical(lines[[1]], case$first_line, label = case$name)
      expect_identical(
        lines[[length(lines)]],
        for_r(case$last_line),
        label = case$name
      )
    }
  }
})

test_that("the worker defaults follow the shared fixture", {
  defaults <- shared_fixture("worker-lifecycle")$defaults

  expect_equal(worker_defaults$call_timeout, defaults$call_timeout)
  expect_equal(worker_defaults$interrupt_grace, defaults$interrupt_grace)
  expect_equal(worker_defaults$idle_timeout, defaults$idle_timeout)
})

test_that("worker failures follow the shared fixture", {
  spec <- shared_fixture("worker-lifecycle")
  failures <- spec$failures
  expect_gt(length(failures$cases), 0)
  withr::local_options(commons.run_r_timeout = failures$seconds)

  for (case in failures$cases) {
    # Windows has no SIGSTOP, which is how the R code stops answering.
    if (identical(case$name, "unresponsive") && is.na(tools::SIGSTOP)) {
      next
    }
    worker <- shared_worker()
    output <- tool_output(worker, case$code$r)

    expected <- case$template
    expected <- gsub("{seconds}", failures$seconds, expected, fixed = TRUE)
    expected <- gsub(
      "{language}",
      spec$substitutions$r$language,
      expected,
      fixed = TRUE
    )
    expect_identical(output, expected, label = case$name)
  }
})

# What a sandboxed worker can signal, and whether its descendants can leave
# its process group, is a cross-language contract: the cases live in
# tests/shared/sandbox-signals.json, and the Python suite runs the same ones.
# Do not restate a case here; add it to the fixture.
#
# Every case runs in a real worker, so these need an installed commons (the
# worker loads the package from the library, not from load_all()).

host_group <- function() {
  stat <- "/proc/self/stat"
  if (file.exists(stat)) {
    # After the parenthesised command name: state, ppid, then pgrp.
    fields <- strsplit(sub(".*\\) ", "", readLines(stat, warn = FALSE)), " ")
    return(as.integer(fields[[1]][[3]]))
  }
  as.integer(system2("ps", c("-o", "pgid=", "-p", Sys.getpid()), stdout = TRUE))
}

# Whether the sandbox confines signals to the worker and its descendants. The
# ABI the kernel reports is not enough on Linux: a policy can refuse the
# ruleset, and the worker then falls back to user namespaces, which do not
# scope signals. Engaging Landlock in a child gives the answer the worker
# would get.
signal_scoping <- function() {
  sysname <- Sys.info()[["sysname"]]
  if (identical(sysname, "Darwin")) {
    return(TRUE)
  }
  if (!identical(sysname, "Linux") ||
    sandbox_capabilities()$landlock_abi < 6) {
    return(FALSE)
  }
  probe <- sprintf(
    paste0(
      "info <- dyn.load(%s); ",
      "cat(.Call(getNativeSymbolInfo('c_sandbox_engage', info), ",
      "character(), character(), NULL, 'landlock', integer(), 'full'))"
    ),
    encodeString(commons_dll_path(), quote = '"')
  )
  tier <- suppressWarnings(system2(
    file.path(R.home("bin"), "Rscript"),
    c("-e", shQuote(probe)),
    stdout = TRUE,
    stderr = FALSE
  ))
  identical(tier, "landlock")
}

test_that("worker signals follow the shared fixture", {
  spec <- shared_fixture("sandbox-signals")$cases
  expect_gt(length(spec$cases), 0)
  sandboxed <- tryCatch(
    identical(run_r_protection_mode(), "sandbox"),
    error = function(e) FALSE
  )
  skip_if_not(sandboxed, "this host cannot sandbox the worker")

  sysname <- tolower(Sys.info()[["sysname"]])
  # tools has no SIGURG, and its number differs between Linux and macOS.
  sigurg <- if (identical(sysname, "darwin")) 16L else 23L
  scoped <- signal_scoping()

  for (case in spec$cases) {
    if (!is.null(case$platforms) && !sysname %in% unlist(case$platforms)) {
      next
    }
    if (identical(case$requires, "signal_scoping") && !scoped) {
      next
    }

    heard <- withr::local_tempfile()
    victim <- processx::process$new("sh", c("-c", spec$victim), stdout = heard)
    code <- case$code$r
    code <- gsub("{host_pid}", Sys.getpid(), code, fixed = TRUE)
    code <- gsub("{host_group}", host_group(), code, fixed = TRUE)
    code <- gsub("{victim_pid}", victim$get_pid(), code, fixed = TRUE)
    code <- gsub("{sigurg}", sigurg, code, fixed = TRUE)
    worker <- new_r_worker()
    output <- sync_promise(run_r_tool(worker, new_handle_store(), code))@value
    worker_close(worker)
    # Long enough for the victim's trap to run between its sleeps.
    Sys.sleep(0.3)
    victim$kill()

    expect_identical(trimws(output), case$output, label = case$name)
    expect_identical(readLines(heard), character(), label = case$name)
  }
})

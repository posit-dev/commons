test_that("sandbox_capabilities reports all mechanisms", {
  caps <- sandbox_capabilities()
  expect_named(caps, c("landlock_abi", "seccomp", "seatbelt", "userns"))
  expect_type(caps$landlock_abi, "integer")
  expect_type(caps$seccomp, "logical")
  expect_type(caps$seatbelt, "logical")
  expect_type(caps$userns, "logical")
})

test_that("worker_init leaves the worker unsandboxed off Linux and macOS", {
  skip_on_os(c("linux", "mac"))
  res <- callr::r(
    worker_init,
    args = list(
      parent_tmp = tempdir(),
      work_dir = tempdir(),
      dll_path = NA_character_
    )
  )
  expect_false(res)
})

test_that("worker_init errors without the compiled library", {
  skip_on_os(c("windows", "solaris"))
  expect_error(
    callr::r(
      worker_init,
      args = list(
        parent_tmp = tempdir(),
        work_dir = tempdir(),
        dll_path = NA_character_
      )
    ),
    "compiled library"
  )
})

test_that("worker_ensure validates the commons.run_r_sandbox option", {
  withr::local_options(commons.run_r_sandbox = "everything-everywhere")
  expect_error(worker_ensure(new_r_worker()), "commons.run_r_sandbox")
})

sandboxed_worker_probes <- function(sandbox_mode, env = parent.frame()) {
  outside <- file.path(
    dirname(tempdir()),
    paste0("canary-", Sys.getpid(), "-", sandbox_mode)
  )
  dir.create(outside)
  withr::defer(unlink(outside, recursive = TRUE), envir = env)
  writeLines(
    c("secret", rep("padding", 20000)),
    file.path(outside, "secret.txt")
  )

  work_dir <- tempfile("commons-worker-")
  dir.create(work_dir)
  withr::defer(unlink(work_dir, recursive = TRUE), envir = env)

  rs <- callr::r_session$new(
    callr::r_session_options(
      env = worker_scrubbed_env(work_dir, worker_single_thread(sandbox_mode))
    )
  )
  withr::defer(rs$close(), envir = env)
  rs$run(
    function(outside) {
      assign(
        ".commons_inherited_file",
        file(file.path(outside, "secret.txt"), open = "r"),
        envir = globalenv()
      )
    },
    args = list(outside = outside)
  )
  rs$run(
    worker_init,
    args = list(
      parent_tmp = tempdir(),
      work_dir = work_dir,
      dll_path = commons_dll_path(),
      sandbox_mode = sandbox_mode
    )
  )

  rs$run(
    function(outside) {
      denied <- function(expr) {
        tryCatch(
          {
            expr
            "allowed"
          },
          error = function(e) "denied",
          warning = function(w) "denied"
        )
      }
      list(
        read = denied(readLines(file.path(outside, "secret.txt"), n = 1)),
        inherited = denied({
          con <- get(".commons_inherited_file", envir = globalenv())
          seek(con, where = 100000)
          line <- readLines(con, n = 1)
          if (length(line) == 0) {
            warning("inherited descriptor was closed")
          }
          line
        }),
        write = if (
          isTRUE(suppressWarnings(file.create(file.path(outside, "w"))))
        ) {
          "allowed"
        } else {
          "denied"
        },
        socket = denied({
          con <- socketConnection(
            "example.com",
            port = 80,
            blocking = TRUE,
            timeout = 5
          )
          close(con)
        }),
        subprocess = {
          out <- suppressWarnings(system(
            "curl -sS --max-time 5 https://example.com",
            intern = TRUE,
            ignore.stderr = TRUE
          ))
          status <- attr(out, "status")
          if (length(out) > 0 && (is.null(status) || status == 0)) {
            "allowed"
          } else {
            "denied"
          }
        },
        compute = sum(1:10)
      )
    },
    args = list(outside = outside)
  )
}

test_that("an initialized worker is denied reads, writes, and sockets", {
  skip_on_os(c("windows", "solaris"))
  if (identical(Sys.info()[["sysname"]], "Linux")) {
    caps <- sandbox_capabilities()
    skip_if_not(
      caps$landlock_abi >= 1 || caps$userns,
      "kernel lacks both Landlock and user namespaces"
    )
  }

  probes <- sandboxed_worker_probes("auto")
  expect_equal(probes$read, "denied")
  expect_equal(probes$write, "denied")
  expect_equal(probes$socket, "denied")
  expect_equal(probes$subprocess, "denied")
  expect_equal(probes$compute, 55)
})

test_that("the user-namespace tier is denied reads, writes, and sockets", {
  skip_if_not(identical(Sys.info()[["sysname"]], "Linux"))
  skip_if_not(sandbox_capabilities()$userns, "no unprivileged user namespaces")

  probes <- sandboxed_worker_probes("userns")
  expect_equal(probes$read, "denied")
  expect_equal(probes$inherited, "denied")
  expect_equal(probes$write, "denied")
  expect_equal(probes$socket, "denied")
  expect_equal(probes$subprocess, "denied")
  expect_equal(probes$compute, 55)
})

test_that("seccomp-only mode leaves files reachable but not the network", {
  skip_if_not(identical(Sys.info()[["sysname"]], "Linux"))
  skip_if_not(sandbox_capabilities()$seccomp, "no seccomp")

  probes <- sandboxed_worker_probes("seccomp-only")
  expect_equal(probes$read, "allowed")
  expect_equal(probes$socket, "denied")
  expect_equal(probes$compute, 55)
})

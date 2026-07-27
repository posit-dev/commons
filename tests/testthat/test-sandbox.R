test_that("sandbox_capabilities reports all mechanisms", {
  caps <- sandbox_capabilities()
  expect_named(caps, c("landlock_abi", "seccomp", "seatbelt"))
  expect_type(caps$landlock_abi, "integer")
  expect_type(caps$seccomp, "logical")
  expect_type(caps$seatbelt, "logical")
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

test_that("an initialized worker is denied reads, writes, and sockets", {
  skip_on_os(c("windows", "solaris"))
  if (identical(Sys.info()[["sysname"]], "Linux")) {
    skip_if_not(
      sandbox_capabilities()$landlock_abi >= 1,
      "kernel lacks Landlock"
    )
  }

  outside <- file.path(dirname(tempdir()), paste0("canary-", Sys.getpid()))
  dir.create(outside)
  on.exit(unlink(outside, recursive = TRUE), add = TRUE)
  writeLines("secret", file.path(outside, "secret.txt"))

  work_dir <- tempfile("commons-worker-")
  dir.create(work_dir)
  on.exit(unlink(work_dir, recursive = TRUE), add = TRUE)

  # Drive worker_init itself so the sandbox under test is the one run_r
  # engages, not a reimplementation of it.
  rs <- callr::r_session$new()
  on.exit(rs$close(), add = TRUE)
  rs$run(
    worker_init,
    args = list(
      parent_tmp = tempdir(),
      work_dir = work_dir,
      dll_path = commons_dll_path()
    )
  )

  probes <- rs$run(
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

  expect_equal(probes$read, "denied")
  expect_equal(probes$write, "denied")
  expect_equal(probes$socket, "denied")
  expect_equal(probes$subprocess, "denied")
  expect_equal(probes$compute, 55)
})

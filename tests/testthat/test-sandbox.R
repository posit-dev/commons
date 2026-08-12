test_that("sandbox_capabilities reports all mechanisms", {
  caps <- sandbox_capabilities()
  expect_named(caps, c("landlock_abi", "seccomp", "seatbelt", "userns", "nsjail"))
  expect_type(caps$landlock_abi, "integer")
  expect_type(caps$seccomp, "logical")
  expect_type(caps$seatbelt, "logical")
  expect_type(caps$userns, "logical")
  expect_type(caps$nsjail, "logical")
})

test_that("check_run_r_sandbox rejects unsupported Linux hosts", {
  capabilities <- list(
    landlock_abi = 0L,
    seccomp = TRUE,
    seatbelt = FALSE,
    userns = FALSE,
    nsjail = FALSE
  )

  expect_error(
    check_run_r_sandbox(capabilities, "Linux"),
    "neither Landlock nor unprivileged user namespaces"
  )
  capabilities$seccomp <- FALSE
  expect_error(
    check_run_r_sandbox(capabilities, "Linux"),
    "does not support seccomp"
  )
})

test_that("check_run_r_sandbox accepts either Linux filesystem sandbox", {
  capabilities <- list(
    landlock_abi = 1L,
    seccomp = TRUE,
    seatbelt = FALSE,
    userns = FALSE,
    nsjail = FALSE
  )
  expect_invisible(check_run_r_sandbox(capabilities, "Linux"))

  capabilities$landlock_abi <- 0L
  capabilities$userns <- TRUE
  expect_invisible(check_run_r_sandbox(capabilities, "Linux"))
})

test_that("check_run_r_sandbox validates the nsjail backend", {
  capabilities <- list(
    landlock_abi = 0L,
    seccomp = TRUE,
    seatbelt = FALSE,
    userns = TRUE,
    nsjail = FALSE
  )
  expect_error(
    check_run_r_sandbox(capabilities, "Linux", sandbox_mode = "nsjail"),
    "nsjail"
  )

  capabilities$nsjail <- TRUE
  expect_output(
    expect_invisible(
      check_run_r_sandbox(capabilities, "Linux", sandbox_mode = "nsjail")
    ),
    "\\[commons\\]\\[nsjail\\] requested:"
  )
})

test_that("nsjail is rejected outside Linux", {
  capabilities <- list(
    landlock_abi = 0L,
    seccomp = FALSE,
    seatbelt = TRUE,
    userns = FALSE,
    nsjail = TRUE
  )
  expect_error(
    check_run_r_sandbox(capabilities, "Darwin", sandbox_mode = "nsjail"),
    "only supported on Linux"
  )
})

test_that("the nsjail policy retains callr descriptors and network controls", {
  skip_if_not(identical(Sys.info()[["sysname"]], "Linux"))
  work_dir <- tempfile("commons-worker-")
  dir.create(work_dir)
  withr::defer(unlink(work_dir, recursive = TRUE))
  nsjail <- tempfile("nsjail-")
  file.create(nsjail)
  Sys.chmod(nsjail, mode = "0755")
  withr::defer(unlink(nsjail))
  withr::local_options(commons.nsjail_path = nsjail)

  config <- nsjail_worker_spec(
    work_dir = work_dir,
    parent_tmp = tempdir(),
    network = "none",
    env = worker_scrubbed_env(work_dir)
  )
  text <- readLines(config$config, warn = FALSE)
  policy <- nsjail_seccomp("none")

  expect_true(all(paste0("pass_fd: ", c(3, 5, 6)) %in% text))
  expect_true(any(grepl("^clone_newnet: true$", text)))
  expect_match(paste(policy, collapse = "\n"), "socket")
  expect_match(paste(policy, collapse = "\n"), "clone_flags")
  expect_no_match(paste(nsjail_seccomp("full"), collapse = "\n"), "socket")
})

test_that("worker_init refuses to run unsandboxed off Linux and macOS", {
  skip_on_os(c("linux", "mac"))
  expect_error(
    callr::r(
      worker_init,
      args = list(
        parent_tmp = tempdir(),
        work_dir = tempdir(),
        dll_path = NA_character_
      )
    ),
    "only Linux and macOS are supported"
  )
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

sandboxed_worker_probes <- function(
  sandbox_mode,
  network = "none",
  env = parent.frame()
) {
  outside <- file.path(
    dirname(tempdir()),
    paste0("canary-", Sys.getpid(), "-", sandbox_mode, "-", network)
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

  parent_tmp <- tempdir()
  rs <- callr::r_session$new(
    worker_session_options(
      work_dir,
      parent_tmp,
      network,
      sandbox_mode
    )
  )
  withr::defer(rs$close(), envir = env)
  if (!identical(sandbox_mode, "nsjail")) {
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
  }
  rs$run(
    worker_init,
    args = list(
      parent_tmp = parent_tmp,
      work_dir = work_dir,
      dll_path = commons_dll_path(),
      network = network,
      sandbox_mode = sandbox_mode,
      sandboxed_by_nsjail = identical(sandbox_mode, "nsjail")
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
          con <- serverSocket(0)
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
        exec = denied({
          status <- system2("/bin/true")
          if (!identical(status, 0L)) {
            warning("subprocess failed")
          }
          status
        }),
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
  if (identical(Sys.info()[["sysname"]], "Linux")) {
    expect_equal(probes$exec, "allowed")
  }
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
  expect_equal(probes$exec, "allowed")
  expect_equal(probes$compute, 55)
})

test_that("the nsjail tier is denied reads, writes, and sockets", {
  skip_if_not(identical(Sys.info()[["sysname"]], "Linux"))
  caps <- sandbox_capabilities()
  skip_if_not(caps$nsjail, "nsjail is not installed")
  skip_if_not(caps$userns, "no unprivileged user namespaces")

  probes <- sandboxed_worker_probes("nsjail")
  expect_equal(probes$read, "denied")
  expect_equal(probes$write, "denied")
  expect_equal(probes$socket, "denied")
  expect_equal(probes$subprocess, "denied")
  expect_equal(probes$exec, "allowed")
  expect_equal(probes$compute, 55)
})

test_that("full network access leaves the filesystem sandboxed", {
  skip_on_os(c("windows", "solaris"))
  if (identical(Sys.info()[["sysname"]], "Linux")) {
    caps <- sandbox_capabilities()
    skip_if_not(
      caps$landlock_abi >= 1 || caps$userns,
      "kernel lacks both Landlock and user namespaces"
    )
  }

  probes <- sandboxed_worker_probes("auto", network = "full")
  expect_equal(probes$read, "denied")
  expect_equal(probes$socket, "allowed")
  if (identical(Sys.info()[["sysname"]], "Linux")) {
    expect_equal(probes$exec, "allowed")
  }
  expect_equal(probes$compute, 55)
})

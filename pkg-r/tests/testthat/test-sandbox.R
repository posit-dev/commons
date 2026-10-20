test_that("sandbox_capabilities reports all mechanisms", {
  caps <- sandbox_capabilities()
  expect_named(caps, c("landlock_abi", "seccomp", "seatbelt", "userns"))
  expect_type(caps$landlock_abi, "integer")
  expect_type(caps$seccomp, "logical")
  expect_type(caps$seatbelt, "logical")
  expect_type(caps$userns, "logical")
})

test_that("run_r protection rejects unsupported Linux hosts", {
  capabilities <- list(
    landlock_abi = 0L,
    seccomp = TRUE,
    seatbelt = FALSE,
    userns = FALSE
  )

  expect_error(
    run_r_protection_mode(capabilities, "Linux"),
    "neither Landlock nor unprivileged user namespaces"
  )
  capabilities$seccomp <- FALSE
  expect_error(
    run_r_protection_mode(capabilities, "Linux"),
    "does not support seccomp"
  )
})

test_that("run_r protection accepts either Linux filesystem sandbox", {
  capabilities <- list(
    landlock_abi = 1L,
    seccomp = TRUE,
    seatbelt = FALSE,
    userns = FALSE
  )
  expect_identical(run_r_protection_mode(capabilities, "Linux"), "sandbox")

  capabilities$landlock_abi <- 0L
  capabilities$userns <- TRUE
  expect_identical(run_r_protection_mode(capabilities, "Linux"), "sandbox")
})

test_that("unsupported hosts require an explicit guardrail opt-in", {
  capabilities <- list(
    landlock_abi = 0L,
    seccomp = FALSE,
    seatbelt = FALSE,
    userns = FALSE
  )

  expect_error(
    run_r_protection_mode(capabilities, "Windows", FALSE),
    "commons.allow_unsafe_fallback = TRUE",
    fixed = TRUE
  )
  withr::local_options(commons.allow_unsafe_fallback = TRUE)
  expect_identical(
    run_r_protection_mode(capabilities, "Windows"),
    "guardrails"
  )
  capabilities$seatbelt <- TRUE
  expect_identical(
    run_r_protection_mode(capabilities, "Darwin"),
    "sandbox"
  )
})

test_that("worker_init refuses to run unsandboxed off Linux and macOS", {
  skip_on_os(c("linux", "mac"))
  expect_error(
    callr::r(
      worker_call,
      args = list(
        runtime = worker_runtime(),
        name = "worker_init",
        args = list(
          parent_tmp = tempdir(),
          work_dir = tempdir(),
          dll_path = NA_character_
        )
      )
    ),
    "only Linux and macOS are supported"
  )
})

test_that("worker_init errors without the compiled library", {
  skip_on_os(c("windows", "solaris"))
  expect_error(
    callr::r(
      worker_call,
      args = list(
        runtime = worker_runtime(),
        name = "worker_init",
        args = list(
          parent_tmp = tempdir(),
          work_dir = tempdir(),
          dll_path = NA_character_
        )
      )
    ),
    "compiled library"
  )
})

test_that("worker_init permits the explicit guardrail mode", {
  expect_true(callr::r(
    worker_call,
    args = list(
      runtime = worker_runtime(),
      name = "worker_init",
      args = list(
        parent_tmp = tempdir(),
        work_dir = tempdir(),
        dll_path = NA_character_,
        protection = "guardrails"
      )
    )
  ))
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
    worker_call,
    args = list(
      runtime = worker_runtime(),
      name = "worker_init",
      args = list(
        parent_tmp = tempdir(),
        work_dir = work_dir,
        dll_path = commons_dll_path(),
        network = network,
        sandbox_mode = sandbox_mode
      )
    )
  )

  # A host process outside the sandbox listens on a pathname socket in each
  # directory, as a local database or system daemon would.
  peer_sockets <- c(
    outside = file.path(outside, "peer.sock"),
    work = file.path(work_dir, "peer.sock")
  )
  if (
    identical(Sys.info()[["sysname"]], "Linux") && nzchar(Sys.which("perl"))
  ) {
    listen_on_pathname_sockets(peer_sockets, env)
  }

  rs$run(
    function(outside, peer_sockets) {
      perl_report <- function(out) {
        if (!identical(attr(out, "status"), 127L)) {
          pairs <- strsplit(out, "=", fixed = TRUE)
          stats::setNames(lapply(pairs, `[[`, 2), vapply(pairs, `[[`, "", 1))
        }
      }
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
          status <- system2("/bin/sh", c("-c", shQuote("exit 0")))
          if (!identical(status, 0L)) {
            warning("subprocess failed")
          }
          status
        }),
        address_space = if (identical(Sys.info()[["sysname"]], "Linux")) {
          as.double(system2(
            "/bin/sh",
            c("-c", shQuote("ulimit -v")),
            stdout = TRUE
          ))
        },
        # R has no AF_UNIX API, so perl aims a socketpair end at an abstract
        # name: each call reports its errno, and the pair a round trip. The
        # script is a file because `perl -e` opens /dev/null, which the
        # sandbox does not grant; NULL means perl is not installed.
        local_peer = if (identical(Sys.info()[["sysname"]], "Linux")) {
          script <- tempfile(fileext = ".pl")
          writeLines(
            c(
              "use Socket;",
              "socketpair(my $a, my $b, AF_UNIX, SOCK_DGRAM, 0) or die $!;",
              "my $name = pack_sockaddr_un(\"\\0commons-probe\");",
              "my %r;",
              "$r{connect} = connect($a, $name) ? 0 : $! + 0;",
              "$r{sendto} = defined(send($a, \"x\", 0, $name)) ? 0 : $! + 0;",
              "$r{bind} = bind($a, $name) ? 0 : $! + 0;",
              "defined(send($a, \"ping\", 0)) or die $!;",
              "recv($b, $r{pair}, 4, 0);",
              "print map { \"$_=$r{$_}\\n\" } sort keys %r;"
            ),
            script
          )
          perl_report(suppressWarnings(system2("perl", script, stdout = TRUE)))
        },
        # Each name connects to the host listener in that directory and
        # reports its errno.
        pathname_peer = if (identical(Sys.info()[["sysname"]], "Linux")) {
          script <- tempfile(fileext = ".pl")
          writeLines(
            c(
              "use Socket;",
              "my %r;",
              "while (my ($name, $path) = splice(@ARGV, 0, 2)) {",
              "  socket(my $s, AF_UNIX, SOCK_DGRAM, 0) or die $!;",
              "  $r{$name} = connect($s, pack_sockaddr_un($path)) ? 0 : $! + 0;",
              "}",
              "print map { \"$_=$r{$_}\\n\" } sort keys %r;"
            ),
            script
          )
          args <- c(script, rbind(names(peer_sockets), shQuote(peer_sockets)))
          perl_report(suppressWarnings(system2("perl", args, stdout = TRUE)))
        },
        compute = sum(1:10)
      )
    },
    args = list(outside = outside, peer_sockets = peer_sockets)
  )
}

# Binds a datagram socket at each path and keeps it open until the test ends.
listen_on_pathname_sockets <- function(paths, env) {
  script <- tempfile(fileext = ".pl")
  writeLines(
    c(
      "use Socket;",
      "my @held;",
      "for my $path (@ARGV) {",
      "  socket(my $s, AF_UNIX, SOCK_DGRAM, 0) or die $!;",
      "  bind($s, pack_sockaddr_un($path)) or die \"$path: $!\";",
      "  push @held, $s;",
      "}",
      "$| = 1;",
      "print \"ready\\n\";",
      "sleep 600;"
    ),
    script
  )
  listener <- processx::process$new(
    "perl",
    c(script, unname(paths)),
    stdout = "|",
    stderr = "|"
  )
  withr::defer(listener$kill(), envir = env)
  listener$poll_io(10000)
  if (!identical(listener$read_output_lines(), "ready")) {
    stop("pathname socket listener failed: ", listener$read_all_error())
  }
}

# EACCES is 13. Landlock refuses the socket outside every root and allows the
# one under the work directory, a write root.
expect_pathname_peer <- function(pathname_peer) {
  skip_if(is.null(pathname_peer), "perl is not installed")
  abi <- sandbox_capabilities()$landlock_abi
  skip_if(
    abi < 9,
    paste("pathname sockets need Landlock ABI 9; this kernel reports", abi)
  )
  expect_equal(pathname_peer$outside, "13")
  expect_equal(pathname_peer$work, "0")
}

# EPERM is 1. Without the filter, connect() and the addressed send() fail
# with ECONNREFUSED (111), since nothing listens on the name, and bind()
# succeeds.
expect_local_peer <- function(local_peer, screened) {
  skip_if(is.null(local_peer), "perl is not installed")
  refused <- if (screened) "1" else "111"
  expect_equal(local_peer$connect, refused)
  expect_equal(local_peer$sendto, refused)
  expect_equal(local_peer$bind, if (screened) "1" else "0")
  expect_equal(local_peer$pair, "ping")
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
  expect_equal(probes$exec, "allowed")
  if (identical(Sys.info()[["sysname"]], "Linux")) {
    expect_lte(probes$address_space, 8 * 1024^2)
    expect_local_peer(probes$local_peer, screened = TRUE)
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
  expect_local_peer(probes$local_peer, screened = TRUE)
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
  expect_equal(probes$exec, "allowed")
  if (identical(Sys.info()[["sysname"]], "Linux")) {
    expect_local_peer(probes$local_peer, screened = FALSE)
  }
  expect_equal(probes$compute, 55)
  # Under network = "none" the seccomp filter refuses every connect() first,
  # so only full network shows what Landlock decides.
  if (identical(Sys.info()[["sysname"]], "Linux")) {
    expect_pathname_peer(probes$pathname_peer)
  }
})

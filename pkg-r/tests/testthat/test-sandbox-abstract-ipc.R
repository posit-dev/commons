# Runner for tests/shared/sandbox-abstract-ipc.json. It checks the C source,
# because an installed seccomp filter cannot be read back. The live behaviour
# is probed in test-sandbox.R.

sandbox_c_source <- function() {
  path <- test_path("../../src/sandbox.c")
  skip_if_not(file.exists(path), "package sources are present only in dev")
  readLines(path, warn = FALSE)
}

# The lines of one top-level function, up to the next one.
c_function <- function(src, name) {
  starts <- grep("^static ", src)
  from <- grep(paste0("^static [a-z_ ]+\\b", name, "\\("), src)
  expect_length(from, 1)
  later <- starts[starts > from]
  to <- if (length(later) > 0) later[[1]] - 1 else length(src)
  src[seq(from, to)]
}

test_that("the network filter screens the fixture's address-taking calls", {
  fixture <- shared_fixture("sandbox-abstract-ipc")
  screened <- fixture$seccomp_screened_under_network_none
  expect_gt(length(screened$always), 0)
  expect_gt(length(screened$when_addressed), 0)

  network_filter <- c_function(sandbox_c_source(), "network_engage")
  for (name in c(screened$always, screened$when_addressed)) {
    expect_true(
      any(grepl(paste0("__NR_", name, ","), network_filter, fixed = TRUE)),
      info = paste("network_engage does not screen", name)
    )
  }
})

test_that("the filters screen socketcall and pidfd_getfd", {
  src <- sandbox_c_source()
  network_filter <- c_function(src, "network_engage")
  expect_true(any(grepl("__NR_socketcall,", network_filter, fixed = TRUE)))

  sandbox_filter <- c_function(src, "seccomp_engage")
  expect_true(any(grepl(
    "SANDBOX_SCREEN(__NR_pidfd_getfd)",
    sandbox_filter,
    fixed = TRUE
  )))
})

test_that("socketcall allows only the fixture's sub-calls", {
  fixture <- shared_fixture("sandbox-abstract-ipc")
  allowed <- fixture$socketcall_allowed_under_network_none
  expect_gt(length(allowed), 0)

  network_filter <- c_function(sandbox_c_source(), "network_engage")
  listed <- regmatches(
    network_filter,
    regexpr("(?<=BPF_K, )SYS_[A-Z]+", network_filter, perl = TRUE)
  )
  expect_setequal(listed, paste0("SYS_", toupper(allowed)))
})

test_that("landlock_engage scopes abstract sockets from the fixture ABI", {
  fixture <- shared_fixture("sandbox-abstract-ipc")
  scope <- fixture$landlock_abstract_unix_scope
  # sandbox.c defines the flag itself, as LL_ in place of LANDLOCK_.
  flag <- sub("^LANDLOCK_", "LL_", scope$flag)

  src <- sandbox_c_source()
  expect_true(any(grepl(
    paste0("#define ", flag, " (1ULL << 0)"),
    src,
    fixed = TRUE
  )))
  expect_true(any(grepl(
    paste0("#define LL_SCOPE_MIN_ABI ", scope$min_abi),
    src,
    fixed = TRUE
  )))

  engage <- c_function(src, "landlock_engage")
  expect_true(any(grepl("abi >= LL_SCOPE_MIN_ABI", engage, fixed = TRUE)))
  expect_true(any(grepl(paste0(".scoped = ", flag), engage, fixed = TRUE)))
})

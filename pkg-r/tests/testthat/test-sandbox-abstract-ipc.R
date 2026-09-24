# Runner for tests/shared/sandbox-abstract-ipc.json. It checks the C source,
# because an installed seccomp filter cannot be read back.

sandbox_c_source <- function() {
  path <- test_path("../../src/sandbox.c")
  skip_if_not(file.exists(path), "package sources are present only in dev")
  readLines(path, warn = FALSE)
}

test_that("the network filter screens the fixture's address-taking calls", {
  fixture <- shared_fixture("sandbox-abstract-ipc")
  screened <- fixture$seccomp_screened_under_network_none
  expect_gt(length(screened$always), 0)
  expect_gt(length(screened$when_addressed), 0)

  src <- sandbox_c_source()
  network_filter <- src[seq(
    from = grep("static void network_engage", src, fixed = TRUE)[[1]],
    to = length(src)
  )]
  for (name in c(screened$always, screened$when_addressed)) {
    expect_true(
      any(grepl(paste0("__NR_", name), network_filter, fixed = TRUE)),
      info = paste("network_engage does not screen", name)
    )
  }
})

test_that("the filters screen socketcall and pidfd_getfd", {
  src <- sandbox_c_source()
  network_filter <- src[seq(
    from = grep("static void network_engage", src, fixed = TRUE)[[1]],
    to = length(src)
  )]
  expect_true(any(grepl("__NR_socketcall", network_filter, fixed = TRUE)))

  sandbox_filter <- src[seq(
    from = grep("static void seccomp_engage", src, fixed = TRUE)[[1]],
    to = length(src)
  )]
  expect_true(any(grepl("__NR_pidfd_getfd", sandbox_filter, fixed = TRUE)))
})

test_that("socketcall allows only the fixture's sub-calls", {
  fixture <- shared_fixture("sandbox-abstract-ipc")
  allowed <- fixture$socketcall_allowed_under_network_none
  expect_gt(length(allowed), 0)

  src <- sandbox_c_source()
  network_filter <- src[seq(
    from = grep("static void network_engage", src, fixed = TRUE)[[1]],
    to = length(src)
  )]
  listed <- regmatches(
    network_filter,
    regexpr("(?<=BPF_K, )SYS_[A-Z]+", network_filter, perl = TRUE)
  )
  expect_setequal(listed, paste0("SYS_", toupper(allowed)))
})

test_that("landlock_engage scopes abstract sockets from the fixture ABI", {
  fixture <- shared_fixture("sandbox-abstract-ipc")
  scope <- fixture$landlock_abstract_unix_scope

  src <- paste(sandbox_c_source(), collapse = "\n")
  expect_true(grepl(scope$flag, src, fixed = TRUE))
  expect_true(
    grepl(paste0("LL_SCOPE_MIN_ABI ", scope$min_abi), src, fixed = TRUE)
  )
})

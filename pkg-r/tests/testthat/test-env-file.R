# The repository-root .env reader, against the shared cases.
for (case in shared_fixture("live-warehouse-env")$env_file$cases) {
  test_that(case$name, {
    names <- c(names(case$expected), unlist(case$unset))
    withr::local_envvar(stats::setNames(rep(NA, length(names)), names))
    withr::local_envvar(unlist(case$environment))
    path <- withr::local_tempfile(lines = unlist(case$lines))

    local({
      local_env_file(path)
      for (name in names(case$expected)) {
        expect_identical(Sys.getenv(name, unset = NA), case$expected[[name]])
      }
      for (name in unlist(case$unset)) {
        expect_true(is.na(Sys.getenv(name, unset = NA)))
      }
    })

    from_file <- setdiff(names(case$expected), names(case$environment))
    for (name in from_file) {
      expect_true(is.na(Sys.getenv(name, unset = NA)))
    }
  })
}

test_that("a missing .env file changes nothing", {
  before <- Sys.getenv()
  local_env_file(file.path(withr::local_tempdir(), ".env"))
  expect_identical(Sys.getenv(), before)
})

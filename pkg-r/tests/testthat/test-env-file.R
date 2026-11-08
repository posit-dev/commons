# The repository-root .env reader, against the shared cases.
for (case in shared_fixture("live-warehouse-env")$env_file$cases) {
  test_that(case$name, {
    # Windows cannot hold an empty variable: setting one unsets it.
    if (any(unlist(case$environment) == "")) {
      skip_on_os("windows")
    }
    # withr cannot restore an empty set of variables, so skip empty ones.
    names <- c(names(case$expected), unlist(case$unset))
    if (length(names) > 0) {
      withr::local_envvar(stats::setNames(rep(NA, length(names)), names))
    }
    if (length(case$environment) > 0) {
      withr::local_envvar(unlist(case$environment))
    }
    path <- withr::local_tempfile()
    writeLines(as.character(unlist(case$lines)), path)
    before <- Sys.getenv()

    local({
      local_env_file(path)
      for (name in names(case$expected)) {
        expect_identical(Sys.getenv(name, unset = NA), case$expected[[name]])
      }
      for (name in unlist(case$unset)) {
        expect_true(is.na(Sys.getenv(name, unset = NA)))
      }
    })

    # Compared with identical() so a failure prints no environment values.
    expect_true(identical(Sys.getenv(), before))
  })
}

test_that("the .env is read from the repository root", {
  skip_if(testthat::is_checking(), "R CMD check runs the tests from a copy")
  expect_true(dir.exists(file.path(test_path("..", "..", ".."), "tests", "shared")))
})

test_that("a missing .env is not read", {
  root <- withr::local_tempdir()
  dir.create(file.path(root, "tests", "shared"), recursive = TRUE)
  expect_null(env_file_path(root))

  before <- Sys.getenv()
  local_env_file(NULL)
  # Compared with identical() so a failure prints no environment values.
  expect_true(identical(Sys.getenv(), before))
})

test_that("a .env outside a checkout is not read", {
  root <- withr::local_tempdir()
  writeLines("COMMONS_ENV_FILE_STRAY=yes", file.path(root, ".env"))
  expect_null(env_file_path(root))

  dir.create(file.path(root, "tests", "shared"), recursive = TRUE)
  expect_identical(env_file_path(root), file.path(root, ".env"))
})

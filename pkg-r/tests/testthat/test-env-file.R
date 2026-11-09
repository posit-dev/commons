# The repository-root .env reader, against the shared cases.
for (case in shared_fixture("live-warehouse-env")$env_file$cases) {
  test_that(case$name, {
    # Windows cannot hold an empty variable: setting one unsets it.
    if (any(unlist(case$environment) == "")) {
      skip_on_os("windows")
    }
    # withr rejects a named vector with no elements.
    names <- c(names(case$expected), unlist(case$unset))
    if (length(names) > 0) {
      withr::local_envvar(stats::setNames(rep(NA, length(names)), names))
    }
    withr::local_envvar(unlist(case$environment))
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
  expect_true(dir.exists(file.path(repo_root(), "tests", "shared")))
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

test_that("R CMD check does not read the checkout's .env", {
  root <- withr::local_tempdir()
  dir.create(file.path(root, "tests", "shared"), recursive = TRUE)
  writeLines("COMMONS_ENV_FILE_CHECKOUT=yes", file.path(root, ".env"))
  withr::local_envvar(COMMONS_ENV_FILE_CHECKOUT = NA)

  local({
    withr::local_envvar(TESTTHAT_IS_CHECKING = "true")
    local_repo_env_file(root)
    expect_true(is.na(Sys.getenv("COMMONS_ENV_FILE_CHECKOUT", unset = NA)))
  })
  local({
    withr::local_envvar(TESTTHAT_IS_CHECKING = "false")
    local_repo_env_file(root)
    expect_identical(Sys.getenv("COMMONS_ENV_FILE_CHECKOUT"), "yes")
  })
})

test_that("an unreadable line is not quoted, and the environment is reset", {
  path <- withr::local_tempfile(lines = c(
    "COMMONS_ENV_FILE_SET=from-file",
    "COMMONS_ENV_FILE_SECRET-WITHOUT-EQUALS",
    "COMMONS_ENV_FILE_ADDED=from-file"
  ))
  withr::local_envvar(
    COMMONS_ENV_FILE_SET = "from-environment",
    COMMONS_ENV_FILE_ADDED = NA
  )

  local({
    expect_warning(local_env_file(path), "could not read", class = "rlang_warning")
    expect_identical(Sys.getenv("COMMONS_ENV_FILE_SET"), "from-environment")
    expect_identical(Sys.getenv("COMMONS_ENV_FILE_ADDED"), "from-file")
  })
  expect_true(is.na(Sys.getenv("COMMONS_ENV_FILE_ADDED", unset = NA)))

  withr::local_options(warn = 2)
  expect_error(local({
    local_env_file(path)
  }))
  expect_identical(Sys.getenv("COMMONS_ENV_FILE_SET"), "from-environment")
  expect_true(is.na(Sys.getenv("COMMONS_ENV_FILE_ADDED", unset = NA)))
})

test_that("the unreadable-line warning does not quote the line", {
  path <- withr::local_tempfile(lines = "COMMONS_ENV_FILE_SECRET-WITHOUT-EQUALS")
  warning <- expect_warning(local_env_file(path))
  expect_false(grepl("SECRET", conditionMessage(warning), fixed = TRUE))
})

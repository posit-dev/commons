# Read the optional repository-root .env the live warehouse tests use. The
# rules both suites share are pinned in tests/shared/live-warehouse-env.json
# under env_file, and README.md describes the file.

repo_root <- function() test_path("..", "..", "..")

# The .env at `root`, when `root` is a checkout of this repository.
env_file_path <- function(root = repo_root()) {
  path <- file.path(root, ".env")
  if (dir.exists(file.path(root, "tests", "shared")) && file.exists(path)) {
    return(path)
  }
  NULL
}

# Read the checkout's .env until `envir` ends. R CMD check skips it: the copy
# it tests can sit inside the checkout, beside the developer's file.
local_repo_env_file <- function(root = repo_root(), envir = parent.frame()) {
  if (testthat::is_checking()) {
    return(invisible())
  }
  local_env_file(env_file_path(root), envir)
}

# Set each variable the file names that the environment lacks, until `envir`
# ends. readRenviron() overwrites what is already set, and its warning about an
# unreadable line quotes the line, so the environment is reset whatever
# happens and the warning is replaced by one without the text.
local_env_file <- function(path, envir = parent.frame()) {
  if (is.null(path)) {
    return(invisible())
  }
  before <- as.list(Sys.getenv())
  unreadable <- FALSE
  after <- tryCatch(
    {
      withCallingHandlers(
        readRenviron(path),
        warning = function(w) {
          unreadable <<- TRUE
          invokeRestart("muffleWarning")
        }
      )
      as.list(Sys.getenv())
    },
    finally = reset_env(before)
  )

  added <- setdiff(names(after), names(before))
  if (length(added) > 0) {
    withr::local_envvar(unlist(after[added]), .local_envir = envir)
  }
  if (unreadable) {
    cli::cli_warn("{.file {path}} has lines R could not read as {.code KEY=value}.")
  }
  invisible()
}

reset_env <- function(before) {
  now <- as.list(Sys.getenv())
  Sys.unsetenv(setdiff(names(now), names(before)))
  kept <- intersect(names(before), names(now))
  changed <- kept[!vapply(kept, function(name) identical(before[[name]], now[[name]]), logical(1))]
  if (length(changed) > 0) {
    do.call(Sys.setenv, before[changed])
  }
}

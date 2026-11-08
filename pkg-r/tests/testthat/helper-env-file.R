# Read the optional repository-root .env the live warehouse tests use. The
# rules both suites share are pinned in tests/shared/live-warehouse-env.json
# under env_file, and README.md describes the file.

# The .env at `root`, when `root` is a checkout of this repository.
env_file_path <- function(root = test_path("..", "..", "..")) {
  path <- file.path(root, ".env")
  if (dir.exists(file.path(root, "tests", "shared")) && file.exists(path)) {
    return(path)
  }
  NULL
}

# Set each variable the file names that the environment lacks, until `envir`
# ends. readRenviron() parses the file but overwrites what is already set, so
# those values are put back and only the new names are kept.
local_env_file <- function(path, envir = parent.frame()) {
  if (is.null(path)) {
    return(invisible())
  }
  before <- as.list(Sys.getenv())
  readRenviron(path)
  after <- as.list(Sys.getenv())

  kept <- intersect(names(before), names(after))
  overwritten <- kept[!mapply(identical, before[kept], after[kept])]
  if (length(overwritten) > 0) {
    do.call(Sys.setenv, before[overwritten])
  }

  added <- setdiff(names(after), names(before))
  if (length(added) == 0) {
    return(invisible())
  }
  Sys.unsetenv(added)
  withr::local_envvar(unlist(after[added]), .local_envir = envir)
}

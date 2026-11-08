# Read the optional repository-root .env the live warehouse tests use. The
# rules are pinned in tests/shared/live-warehouse-env.json under env_file, and
# README.md describes the file.

# The variables .env lines set, before the environment is consulted.
env_file_values <- function(lines) {
  lines <- trimws(lines)
  lines <- lines[nzchar(lines) & !startsWith(lines, "#") & grepl("=", lines)]
  names <- trimws(sub("=.*", "", lines))
  values <- trimws(sub("^[^=]*=", "", lines))
  first <- substr(values, 1, 1)
  quoted <- nchar(values) >= 2 &
    first %in% c("\"", "'") &
    first == substr(values, nchar(values), nchar(values))
  values[quoted] <- substr(values[quoted], 2, nchar(values[quoted]) - 1)
  stats::setNames(values, names)[nzchar(names)]
}

# Set each variable a .env file names that the environment lacks, until
# `envir` ends.
local_env_file <- function(path, envir = parent.frame()) {
  if (!file.exists(path)) {
    return(invisible())
  }
  values <- env_file_values(readLines(path, warn = FALSE))
  values <- values[is.na(Sys.getenv(names(values), unset = NA))]
  withr::local_envvar(values, .local_envir = envir)
}

# Read the optional repository-root .env for this test run; README.md
# describes it. A variable set in the environment wins over the file.
local({
  path <- test_path("..", "..", "..", ".env")
  if (!file.exists(path)) {
    return()
  }
  lines <- trimws(readLines(path, warn = FALSE))
  lines <- lines[nzchar(lines) & !startsWith(lines, "#") & grepl("=", lines)]
  names <- trimws(sub("=.*", "", lines))
  values <- trimws(sub("^[^=]*=", "", lines))
  quoted <- nchar(values) >= 2 &
    substr(values, 1, 1) %in% c("\"", "'") &
    substr(values, 1, 1) == substr(values, nchar(values), nchar(values))
  values[quoted] <- substr(values[quoted], 2, nchar(values[quoted]) - 1)
  unset <- nzchar(names) & is.na(Sys.getenv(names, unset = NA))
  withr::local_envvar(
    stats::setNames(values[unset], names[unset]),
    .local_envir = testthat::teardown_env()
  )
})

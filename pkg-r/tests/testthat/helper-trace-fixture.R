# Writes the trace committed under tests/shared/traces/r/ into `directory` by
# running trace-fixture.R in a process of its own, and returns its path. To
# regenerate the committed trace, from the repository root:
#
#   rm -f tests/shared/traces/r/trace-0.jsonl && cd pkg-r &&
#     Rscript -e 'devtools::load_all(quiet = TRUE); write_trace_fixture("../tests/shared/traces/r")' &&
#     cd .. && scripts/sync-shared.sh
write_trace_fixture <- function(directory) {
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  directory <- normalizePath(directory)
  existing <- list.files(directory, pattern = "[.]jsonl$")
  if (length(existing) > 0) {
    cli::cli_abort(
      "{.path {directory}} already has a trace: {.file {existing[[1]]}}."
    )
  }

  source_dir <- if (pkgload::is_dev_package("commons")) {
    pkgload::pkg_path(test_path())
  } else {
    ""
  }
  # R CMD check sets R_TESTS to a startup file the child can't find.
  withr::local_envvar(
    R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep),
    R_TESTS = NA
  )
  status <- system2(
    file.path(R.home("bin"), "Rscript"),
    shQuote(c(
      normalizePath(test_path("trace-fixture.R")),
      directory,
      source_dir
    ))
  )

  # The exporter's trace-latest.jsonl links to the file it names.
  unlink(file.path(directory, "trace-latest.jsonl"))
  written <- list.files(
    directory,
    pattern = "^trace-[0-9]+[.]jsonl$",
    full.names = TRUE
  )
  if (!identical(status, 0L) || length(written) != 1) {
    unlink(written)
    cli::cli_abort("trace-fixture.R failed with status {status}.")
  }

  lines <- readLines(written, warn = FALSE)
  writeLines(
    gsub(
      '("key":"process[.]owner","value":[{]"stringValue":")[^"]*"',
      '\\1developer"',
      lines
    ),
    written
  )
  written
}

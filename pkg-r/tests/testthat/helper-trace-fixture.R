# Writes the trace committed under tests/shared/traces/r/ into `directory` by
# running trace-fixture.R in a process of its own, and returns its path. To
# regenerate the committed trace, from the repository root:
#
#   find tests/shared/traces/r -name '*.jsonl' -delete && cd pkg-r &&
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
      trace_fixture_source()
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

  lines <- vapply(
    readLines(written, warn = FALSE),
    function(line) {
      envelope <- tidy_trace_envelope(
        jsonlite::fromJSON(line, simplifyVector = FALSE)
      )
      as.character(jsonlite::toJSON(
        envelope,
        auto_unbox = TRUE,
        null = "null",
        digits = NA
      ))
    },
    character(1),
    USE.NAMES = FALSE
  )
  writeLines(lines, written)

  leaked <- trace_private_strings(written)
  if (length(leaked) > 0) {
    unlink(written)
    cli::cli_abort("The trace names {.val {leaked}}, so it was not kept.")
  }
  written
}

# The package source trace-fixture.R loads, or "" for the installed package.
trace_fixture_source <- function() {
  if (pkgload::is_dev_package("commons")) {
    pkgload::pkg_path(test_path())
  } else {
    ""
  }
}

# Replaces the login name otelsdk records as process.owner, and drops the
# events on DBI's spans, whose error backtraces name local files.
tidy_trace_envelope <- function(envelope) {
  envelope$resourceSpans <- lapply(envelope$resourceSpans, function(resource) {
    resource$resource$attributes <- lapply(
      resource$resource$attributes,
      function(attribute) {
        if (identical(attribute$key, "process.owner")) {
          attribute$value <- list(stringValue = "developer")
        }
        attribute
      }
    )
    resource$scopeSpans <- lapply(resource$scopeSpans, function(scope_spans) {
      if (startsWith(scope_spans$scope$name %||% "", "org.r-dbi.")) {
        scope_spans$spans <- lapply(scope_spans$spans, function(span) {
          span$events <- NULL
          span
        })
      }
      scope_spans
    })
    resource
  })
  envelope
}

# Which of a file URL, the package's paths, and the login name (as a path
# component or a whole quoted value) appear in the trace at `path`.
trace_private_strings <- function(path) {
  roots <- c(trace_fixture_source(), system.file(package = "commons"))
  user <- Sys.info()[["user"]]
  generic <- c("root", "user", "admin", "runner", "developer")
  private <- c(
    "file://",
    normalizePath(roots[nzchar(roots)]),
    if (nchar(user) >= 3 && !tolower(user) %in% generic) {
      c(paste0("/", user, "/"), paste0("\\", user, "\\"), paste0("\"", user, "\""))
    }
  )
  text <- paste(readLines(path, warn = FALSE), collapse = "\n")
  private[vapply(private, grepl, logical(1), x = text, fixed = TRUE)]
}

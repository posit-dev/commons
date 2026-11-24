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

# Every string in a JSON value, including the strings inside a string that
# is itself JSON, as some attributes are.
json_strings <- function(x) {
  if (is.list(x)) {
    return(unlist(lapply(x, json_strings), use.names = FALSE))
  }
  if (!is.character(x)) {
    return(character())
  }
  nested <- if (grepl('^\\s*[[{"]', x)) {
    tryCatch(
      json_strings(jsonlite::fromJSON(x, simplifyVector = FALSE)),
      error = function(err) character()
    )
  }
  c(x, nested)
}

# Which of a file URL, the package's paths, and the login name appear in the
# trace at `path`. The trace is decoded first, so a path is found however many
# times it was JSON encoded. The login name counts only as a path part, since
# as a whole value it can be an ordinary word such as "text";
# tidy_trace_envelope() replaces process.owner, the value that names it.
trace_private_strings <- function(
  path,
  user = Sys.info()[["user"]],
  roots = trace_package_roots()
) {
  strings <- unlist(
    lapply(readLines(path, warn = FALSE), function(line) {
      json_strings(jsonlite::fromJSON(line, simplifyVector = FALSE))
    }),
    use.names = FALSE
  )
  private <- unique(c("file://", roots, gsub("\\", "/", roots, fixed = TRUE)))
  found <- private[vapply(
    private,
    function(text) any(grepl(text, strings, fixed = TRUE)),
    logical(1)
  )]
  generic <- c("root", "user", "admin", "runner", "developer")
  if (nchar(user) >= 3 && !tolower(user) %in% generic) {
    paths <- grep("[/\\\\]", strings, value = TRUE)
    if (user %in% unlist(strsplit(paths, "[/\\\\]"))) {
      found <- c(found, user)
    }
  }
  found
}

trace_package_roots <- function() {
  roots <- c(trace_fixture_source(), system.file(package = "commons"))
  normalizePath(roots[nzchar(roots)])
}

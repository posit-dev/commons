data_dict_executable <- function() {
  path <- unname(Sys.which("data-dict"))
  skip_if(!nzchar(path), "data-dict CLI is not installed")
  path
}

data_dict_cli_run <- function(args) {
  executable <- data_dict_executable()
  version <- processx::run(
    executable,
    "--version",
    error_on_status = FALSE,
    echo = FALSE
  )$stdout
  result <- processx::run(
    executable,
    args,
    error_on_status = FALSE,
    echo = FALSE
  )
  attr(result, "data_dict_version") <- trimws(version)
  result
}

data_dict_cli_context <- function(result) {
  paste(
    attr(result, "data_dict_version"),
    trimws(result$stdout),
    trimws(result$stderr),
    sep = "\n"
  )
}

# The conformance corpus is a cross-language fixture: both suites read the
# same YAML files. These read the synced copy, as every shared fixture does.
definition_fixture_path <- function(name, kind = "valid") {
  test_path("fixtures", "shared", "definition-export", kind, name)
}

definition_fixture_paths <- function(kind) {
  sort(Sys.glob(test_path(
    "fixtures",
    "shared",
    "definition-export",
    kind,
    "*.yaml"
  )))
}

# Which data-dict problem code each invalid fixture must produce. Shared, so
# both suites hold one copy of the mapping.
definition_fixture_error_code <- function(path) {
  shared_fixture("definitions")$invalid[[basename(path)]]
}

definition_export_contract <- function(export) {
  tables <- export$tables
  out <- list()
  for (table in tables) {
    definitions <- table$definitions %||% list()
    for (definition in definitions) {
      translation <- definition$translations %||% list()
      translation <- Filter(
        function(item) identical(item$target, "SQL(duckdb)"),
        translation
      )
      translation <- if (length(translation)) translation[[1]] else list()
      key <- paste(table$name, definition$name, sep = "::")
      out[[key]] <- list(
        expression = definition$expression,
        kind = definition$kind,
        type = definition$type,
        columns = as.character(unlist(definition$columns, use.names = FALSE)),
        definitions = as.character(unlist(
          definition$definitions,
          use.names = FALSE
        )),
        translation = list(
          target = translation$target,
          code = translation$code,
          error = translation$error,
          notes = as.character(unlist(translation$notes, use.names = FALSE))
        )
      )
    }
  }
  out
}

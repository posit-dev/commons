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

definition_fixture_paths <- function(kind) {
  sort(Sys.glob(test_path(
    "fixtures",
    "definition-export",
    kind,
    "*.yaml"
  )))
}

definition_fixture_error_code <- function(path) {
  codes <- c(
    "between-temporal.yaml" = "S21",
    "columns-non-filter.yaml" = "S21",
    "columns-transitive.yaml" = "S21",
    "cycle.yaml" = "S34",
    "duplicate.yaml" = "S10",
    "nested-aggregate.yaml" = "S30",
    "parse.yaml" = "S19",
    "regex-engine.yaml" = "S21",
    "shadow.yaml" = "S33",
    "type.yaml" = "S21",
    "unknown.yaml" = "S20"
  )
  unname(codes[[basename(path)]])
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

#' Configure a data source
#'
#' @param include Objects or namespaces to expose. DBI sources accept exact
#'   table names, one [DBI::Id()], or a list of IDs. An ID ending before its
#'   `table` component selects that namespace and its descendants. Boards
#'   accept a named character vector mapping local table names to pin names.
#' @param exclude Unqualified object-name globs to remove after `include` is
#'   resolved, such as `"TMP_*"`.
#' @param sample_rows The number of live rows to include when a table is
#'   described. The default, `0`, reads schema metadata only.
#' @param genie An optional configuration from [genie_agent()] for importing
#'   context from one Databricks Genie Agent.
#'
#' @return A `commons_data_source_options` object for [data_source()].
#' @export
data_source_options <- function(
  include = NULL,
  exclude = NULL,
  sample_rows = 0L,
  genie = NULL
) {
  if (!is.null(exclude) && (!is.character(exclude) || anyNA(exclude))) {
    cli::cli_abort("{.arg exclude} must be a character vector without missing values.")
  }
  if (!is.null(genie) && !inherits(genie, "commons_genie_agent")) {
    cli::cli_abort("{.arg genie} must come from {.fn genie_agent}.")
  }
  structure(
    list(
      include = include,
      exclude = unique(exclude[nzchar(exclude)]),
      sample_rows = catalog_count(sample_rows, "sample_rows"),
      genie = genie
    ),
    class = "commons_data_source_options"
  )
}

as_data_source_options <- function(
  options,
  tables = NULL,
  kind,
  call = rlang::caller_env()
) {
  if (!is.null(options) && !is.null(tables)) {
    cli::cli_abort(
      "Supply only one of {.arg options} and the deprecated {.arg tables}.",
      call = call
    )
  }
  if (!is.null(tables)) {
    rlang::warn(
      "`tables` is deprecated; use `options = data_source_options(include = ...)` instead.",
      .frequency = "once",
      .frequency_id = "commons-data-source-tables"
    )
    include <- if (identical(kind, "connection")) {
      lapply(table_entries(tables, call), table_entry_id, call = call)
    } else {
      tables
    }
    options <- data_source_options(include = include)
  }
  if (is.null(options)) {
    options <- data_source_options()
  }
  if (!inherits(options, "commons_data_source_options")) {
    cli::cli_abort(
      "{.arg options} must come from {.fn data_source_options}.",
      call = call
    )
  }
  if (identical(kind, "board") && is.null(options$include)) {
    cli::cli_abort(
      "Board data sources require {.arg options} with an explicit {.arg include} mapping.",
      call = call
    )
  }
  options
}

normalize_connection_includes <- function(include, call = rlang::caller_env()) {
  if (is.null(include)) {
    return(NULL)
  }
  entries <- if (inherits(include, "Id")) {
    list(include)
  } else if (is.character(include)) {
    lapply(include, function(x) DBI::Id(table = x))
  } else if (is.list(include)) {
    include
  } else {
    cli::cli_abort(
      "Connection {.arg include} must be table names, a {.cls DBI::Id}, or a list of IDs.",
      call = call
    )
  }
  valid <- vapply(entries, inherits, logical(1), "Id")
  if (!all(valid)) {
    cli::cli_abort("Every connection {.arg include} entry must be a {.cls DBI::Id}.", call = call)
  }
  for (id in entries) {
    components <- id@name
    if (length(components) == 0 || anyNA(components) || any(!nzchar(components))) {
      cli::cli_abort("{.cls DBI::Id} include entries must have non-empty components.", call = call)
    }
    if (any(grepl("[*?]", components))) {
      cli::cli_abort(
        "Wildcards are not allowed inside {.cls DBI::Id}; put unqualified globs in {.arg exclude}.",
        call = call
      )
    }
  }
  entries
}

select_flat_names <- function(names, options, call = rlang::caller_env()) {
  include <- options$include %||% names
  if (!is.character(include) || anyNA(include) || any(!nzchar(include))) {
    cli::cli_abort("Flat-source {.arg include} must contain non-empty names.", call = call)
  }
  missing <- setdiff(unname(include), names)
  if (length(missing)) {
    cli::cli_abort("{.arg include} names unknown object{?s}: {.val {missing}}.", call = call)
  }
  include[!catalog_excluded(unname(include), options$exclude)]
}

catalog_excluded <- function(names, patterns) {
  if (length(patterns) == 0) {
    return(rep(FALSE, length(names)))
  }
  Reduce(`|`, lapply(patterns, function(pattern) {
    grepl(catalog_glob_regex(pattern), names)
  }))
}

catalog_glob_regex <- function(pattern) {
  escaped <- gsub("([][{}()+.^$|\\\\])", "\\\\\\1", pattern)
  escaped <- gsub("\\*", ".*", escaped)
  escaped <- gsub("\\?", ".", escaped)
  paste0("^", escaped, "$")
}

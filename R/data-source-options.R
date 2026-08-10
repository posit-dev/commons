#' Configure a database data source
#'
#' `data_source_options()` controls which objects a DBI-backed [data_source()]
#' exposes. Character values select literal table names. Use [DBI::Id()] to
#' preserve catalog and schema components or to select a name containing dots.
#'
#' @param include Exact tables to expose: a character vector, a [DBI::Id()], or
#'   a list of `DBI::Id()` objects. An ID without a `table` component represents
#'   a namespace; namespace expansion requires backend catalog support and is
#'   not yet available.
#' @param sample_rows A non-negative integer recording how many rows to sample
#'   when describing a table. Table descriptions do not yet apply this value.
#'
#' @return A `commons_data_source_options` object for [data_source()].
#' @export
data_source_options <- function(include = NULL, sample_rows = 0L) {
  structure(
    list(
      include = normalize_connection_includes(include),
      sample_rows = check_sample_rows(sample_rows)
    ),
    class = "commons_data_source_options"
  )
}

check_data_source_options <- function(
  options,
  tables,
  kind,
  call = rlang::caller_env()
) {
  if (is.null(options)) {
    return(NULL)
  }
  if (!identical(kind, "connection")) {
    cli::cli_abort(
      "{.arg options} can only be used with a DBI connection.",
      call = call
    )
  }
  if (!is.null(tables)) {
    cli::cli_abort(
      "Supply only one of {.arg tables} and {.arg options}.",
      call = call
    )
  }
  if (!inherits(options, "commons_data_source_options")) {
    cli::cli_abort(
      "{.arg options} must come from {.fn data_source_options}.",
      call = call
    )
  }
  options
}

normalize_connection_includes <- function(
  include,
  call = rlang::caller_env()
) {
  if (is.null(include)) {
    return(NULL)
  }

  entries <- if (inherits(include, "Id")) {
    list(include)
  } else if (is.character(include)) {
    if (anyNA(include) || any(!nzchar(include))) {
      cli::cli_abort(
        "Character entries in {.arg include} must be non-empty table names.",
        call = call
      )
    }
    lapply(include, function(table) DBI::Id(table = table))
  } else if (is.list(include)) {
    include
  } else {
    cli::cli_abort(
      paste0(
        "{.arg include} must be a character vector, a {.cls DBI::Id}, ",
        "or a list of {.cls DBI::Id} objects."
      ),
      call = call
    )
  }

  if (length(entries) == 0) {
    cli::cli_abort(
      "{.arg include} must select at least one object.",
      call = call
    )
  }
  if (!all(vapply(entries, inherits, logical(1), "Id"))) {
    cli::cli_abort(
      "Every entry in {.arg include} must be a {.cls DBI::Id}.",
      call = call
    )
  }

  for (id in entries) {
    components <- id@name
    if (any(is.na(components) | components == "")) {
      cli::cli_abort(
        "{.cls DBI::Id} entries in {.arg include} must have non-empty components.",
        call = call
      )
    }
  }

  entries
}

check_sample_rows <- function(sample_rows, call = rlang::caller_env()) {
  valid <- is.numeric(sample_rows) &&
    length(sample_rows) == 1 &&
    !is.na(sample_rows) &&
    is.finite(sample_rows) &&
    sample_rows >= 0 &&
    sample_rows <= .Machine$integer.max &&
    sample_rows == as.integer(sample_rows)
  if (!valid) {
    cli::cli_abort(
      "{.arg sample_rows} must be one non-negative integer.",
      call = call
    )
  }
  as.integer(sample_rows)
}

check_exact_connection_includes <- function(
  include,
  call = rlang::caller_env()
) {
  prefixes <- vapply(
    include,
    function(id) is.na(id@name["table"]),
    logical(1)
  )
  if (any(prefixes)) {
    cli::cli_abort(
      c(
        "Namespace selections in {.arg options} are not yet supported.",
        i = paste0(
          "Select exact tables by adding a {.arg table} component to each ",
          "{.fn DBI::Id}; backend namespace expansion will be added separately."
        )
      ),
      call = call
    )
  }
  invisible(include)
}

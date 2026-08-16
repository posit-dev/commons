#' Display a richly formatted table from a measure
#'
#' `rich_table()` marks a measure result as a table whose authored HTML should
#' be shown directly to the user. The model receives the underlying data, and
#' the original table object remains available through the result's `run_r`
#' handle.
#'
#' Tables with class `gt_tbl` are recognized automatically and do not need to
#' be wrapped in `rich_table()`. Automatic conversion sends the table's
#' underlying data to the model, which can include columns hidden from the
#' rendered table. Wrap the table in `rich_table()` and supply `data` explicitly
#' when the model should receive only selected columns.
#'
#' @param value The original table object.
#' @param data A data frame containing the values to send to the model. By
#'   default, `as.data.frame(value)` is used.
#' @param html A static HTML string or an object supported by
#'   [htmltools::as.tags()]. By default, `htmltools::as.tags(value)` is used.
#'
#' @return A `commons_rich_table` object for returning from a [measure()].
#'
#' @examples
#' table <- data.frame(term = c("Headache", "Nausea"), count = c(7, 5))
#' rich_table(
#'   table,
#'   html = paste0(
#'     "<table><tr><th>Term</th><th>Count</th></tr>",
#'     "<tr><td>Headache</td><td>7</td></tr>",
#'     "<tr><td>Nausea</td><td>5</td></tr></table>"
#'   )
#' )
#'
#' @export
rich_table <- function(value, data = NULL, html = NULL) {
  new_rich_table(
    value,
    data %||% rich_table_data(value),
    html %||% rich_table_html(value)
  )
}

new_rich_table <- function(
  value,
  data,
  html,
  call = rlang::caller_env()
) {
  if (!is.data.frame(data)) {
    cli::cli_abort(
      "{.arg data} must be a data frame.",
      call = call
    )
  }
  structure(
    list(
      value = value,
      data = data,
      html = normalize_rich_table_html(html, call = call)
    ),
    class = "commons_rich_table"
  )
}

rich_table_data <- function(value, call = rlang::caller_env()) {
  tryCatch(
    as.data.frame(value),
    error = function(error) {
      cli::cli_abort(
        c(
          "Can't derive model-facing data from {.arg value}.",
          i = "Supply {.arg data} explicitly."
        ),
        parent = error,
        call = call
      )
    }
  )
}

rich_table_html <- function(value, call = rlang::caller_env()) {
  if (!requireNamespace("htmltools", quietly = TRUE)) {
    cli::cli_abort(
      c(
        "Can't derive user-facing HTML from {.arg value}.",
        i = "Install {.pkg htmltools} or supply {.arg html} explicitly."
      ),
      call = call
    )
  }
  tryCatch(
    htmltools::as.tags(value),
    error = function(error) {
      cli::cli_abort(
        c(
          "Can't derive user-facing HTML from {.arg value}.",
          i = "Supply {.arg html} explicitly."
        ),
        parent = error,
        call = call
      )
    }
  )
}

normalize_rich_table_html <- function(html, call = rlang::caller_env()) {
  if (is.character(html)) {
    rlang::check_string(html, call = call)
    return(as.character(html))
  }
  if (!requireNamespace("htmltools", quietly = TRUE)) {
    cli::cli_abort(
      c(
        "{.arg html} must be a single HTML string.",
        i = "Install {.pkg htmltools} to use an HTML tag object."
      ),
      call = call
    )
  }
  tags <- tryCatch(
    htmltools::as.tags(html),
    error = function(error) {
      cli::cli_abort(
        "{.arg html} must be a single HTML string or an object supported by {.fn htmltools::as.tags}.",
        parent = error,
        call = call
      )
    }
  )
  as.character(tags)
}

as_measure_rich_table <- function(value, call = rlang::caller_env()) {
  if (inherits(value, "commons_rich_table")) {
    return(value)
  }
  if (inherits(value, "gt_tbl")) {
    return(new_rich_table(
      value,
      rich_table_data(value, call = call),
      rich_table_html(value, call = call),
      call = call
    ))
  }
  NULL
}

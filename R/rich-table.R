#' Display a richly formatted table from a measure
#'
#' `rich_table()` marks a measure result as a table whose authored HTML should
#' be shown directly to the user. By default, the model receives the same HTML,
#' so both representations contain the same table structure and values. The
#' original table object remains available through the result's `run_r` handle
#' when using `rich_table()`.
#'
#' Tables with class `gt_tbl` are recognized automatically and do not need to
#' be wrapped in `rich_table()`. Their underlying data frame is made available
#' through the `run_r` handle.
#'
#' @param value The original table object.
#' @param html A static HTML string or an object supported by
#'   [htmltools::as.tags()]. By default, `htmltools::as.tags(value)` is used.
#' @param model_content A single string to send to the model. By default, the
#'   normalized value of `html` is used. Supply this only when deriving a more
#'   compact semantic representation from the same rendered table.
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
rich_table <- function(value, html = NULL, model_content = NULL) {
  html <- normalize_rich_table_html(
    html %||% rich_table_html(value)
  )
  new_rich_table(
    value,
    html,
    model_content %||% html
  )
}

new_rich_table <- function(
  value,
  html,
  model_content = html,
  call = rlang::caller_env()
) {
  structure(
    list(
      value = value,
      html = normalize_rich_table_html(html, call = call),
      model_content = normalize_rich_table_model_content(
        model_content,
        call = call
      )
    ),
    class = "commons_rich_table"
  )
}

recover_rich_table_data <- function(value) {
  as.data.frame(value)
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
    return(html)
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
  rendered <- htmltools::renderTags(tags)
  attach_html_dependencies(
    as.character(rendered$html),
    rendered$dependencies
  )
}

normalize_rich_table_model_content <- function(
  model_content,
  call = rlang::caller_env()
) {
  rlang::check_string(model_content, call = call)
  as.character(model_content)
}

as_measure_rich_table <- function(value, call = rlang::caller_env()) {
  if (inherits(value, "commons_rich_table")) {
    return(value)
  }
  if (inherits(value, "gt_tbl")) {
    html <- normalize_rich_table_html(
      rich_table_html(value, call = call),
      call = call
    )
    return(new_rich_table(
      value,
      html,
      call = call
    ))
  }
  NULL
}

attach_html_dependencies <- function(html, dependencies) {
  if (length(dependencies) == 0) {
    return(html)
  }
  htmltools::attachDependencies(
    htmltools::HTML(html),
    dependencies,
    append = TRUE
  )
}

find_html_dependencies <- function(html) {
  if (!requireNamespace("htmltools", quietly = TRUE)) {
    return(list())
  }
  htmltools::findDependencies(html)
}

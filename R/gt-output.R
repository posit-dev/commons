is_gt_table <- function(x) {
  inherits(x, "gt_tbl")
}

recover_gt_table_data <- function(value, call = rlang::caller_env()) {
  data <- value[["_data"]]
  if (!is.data.frame(data)) {
    cli::cli_abort(
      "Can't recover data from the {.cls gt_tbl} returned by the measure.",
      call = call
    )
  }
  as.data.frame(data)
}

render_gt_table_html <- function(value, call = rlang::caller_env()) {
  if (!requireNamespace("htmltools", quietly = TRUE)) {
    cli::cli_abort(
      c(
        "Can't display the {.cls gt_tbl} returned by the measure.",
        "i" = "Install {.pkg htmltools} to display gt tables."
      ),
      call = call
    )
  }
  tags <- tryCatch(
    htmltools::as.tags(value),
    error = function(error) {
      cli::cli_abort(
        "Can't convert the {.cls gt_tbl} returned by the measure to HTML.",
        parent = error,
        call = call
      )
    }
  )
  rendered <- htmltools::renderTags(tags)
  as.character(rendered$html)
}

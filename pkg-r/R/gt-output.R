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

render_gt_table <- function(value) {
  rendered <- htmltools::renderTags(htmltools::as.tags(value))
  list(
    html = as.character(rendered$html),
    dependencies = rendered$dependencies
  )
}

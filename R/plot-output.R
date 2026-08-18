is_ggplot <- function(x) {
  inherits(x, "ggplot")
}

render_plot_image <- function(plot, alt) {
  dims <- plot_dimensions()
  path <- tempfile("commons-plot-", fileext = ".png")
  on.exit(unlink(path), add = TRUE)
  render_plot_png(plot, path, dims$width, dims$height)
  model <- ellmer::content_image_file(path, resize = "none")
  list(
    model = model,
    html = sprintf(
      paste0(
        "<img class=\"commons-measure-plot\" ",
        "src=\"data:image/png;base64,%s\" alt=\"%s\"/>"
      ),
      model@data,
      html_escape(alt)
    )
  )
}

plot_dimensions <- function() {
  list(width = 768L, height = 512L)
}

render_plot_png <- function(
  plot,
  path,
  width,
  height,
  call = rlang::caller_env()
) {
  if (requireNamespace("ragg", quietly = TRUE)) {
    ragg::agg_png(path, width = width, height = height, scaling = 1.5)
  } else {
    grDevices::png(path, width = width, height = height)
  }
  tryCatch(
    print(plot),
    finally = grDevices::dev.off()
  )

  size <- file.size(path)
  if (is.na(size) || size == 0) {
    cli::cli_abort(
      "Plot rendering did not produce a PNG image.",
      call = call
    )
  }
}

is_ggplot <- function(x) {
  inherits(x, "ggplot")
}

render_plot_image <- function(plot, alt) {
  dims <- plot_dimensions()
  path <- tempfile("commons-plot-", fileext = ".png")
  on.exit(unlink(path), add = TRUE)
  render_plot_png(plot, path, dims$width, dims$height, dims$pixel_ratio)
  model <- model_plot_image(path, dims$width, dims$height)
  list(
    model = model,
    html = sprintf(
      paste0(
        "<img class=\"commons-measure-plot\" ",
        "src=\"data:image/png;base64,%s\" alt=\"%s\"/>"
      ),
      plot_image_data(path),
      html_escape(alt)
    )
  )
}

plot_dimensions <- function() {
  # The model gets the logical size; the browser gets a retina-density source.
  list(width = 768L, height = 512L, pixel_ratio = 2)
}

model_plot_image <- function(path, width, height) {
  image <- magick::image_read(path, strip = TRUE)
  image <- magick::image_resize(image, sprintf("%dx%d>", width, height))
  data <- magick::image_write(image, format = "png")
  ellmer::ContentImageInline("image/png", jsonlite::base64_enc(data))
}

plot_image_data <- function(path) {
  jsonlite::base64_enc(readBin(path, "raw", file.size(path)))
}

render_plot_png <- function(
  plot,
  path,
  width,
  height,
  pixel_ratio,
  call = rlang::caller_env()
) {
  if (requireNamespace("ragg", quietly = TRUE)) {
    ragg::agg_png(
      path,
      width = width * pixel_ratio,
      height = height * pixel_ratio,
      scaling = 1.5 * pixel_ratio
    )
  } else {
    grDevices::png(
      path,
      width = width * pixel_ratio,
      height = height * pixel_ratio,
      res = 72 * pixel_ratio
    )
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

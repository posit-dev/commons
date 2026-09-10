is_ggplot <- function(x) {
  inherits(x, "ggplot")
}

render_plot_image <- function(plot, alt) {
  dims <- plot_dimensions()
  path <- tempfile("commons-plot-", fileext = ".png")
  on.exit(unlink(path), add = TRUE)
  render_plot_png(
    plot,
    path,
    dims$width,
    dims$height,
    dims$pixel_ratio
  )
  # Downscale the UI artifact so both viewers see the same plot layout.
  model <- model_plot_image(path, dims$width, dims$height)
  list(
    model = model,
    html = sprintf(
      paste0(
        "<img class=\"commons-measure-plot\" ",
        "src=\"data:image/png;base64,%s\" alt=\"%s\" ",
        "width=\"%d\" height=\"%d\"/>"
      ),
      plot_image_data(path),
      html_escape(alt),
      dims$width,
      dims$height
    )
  )
}

plot_dimensions <- function() {
  list(width = 768L, height = 512L, pixel_ratio = 2L)
}

model_plot_image <- function(path, width, height) {
  image <- magick::image_read(path, strip = TRUE)
  image <- magick::image_resize(image, sprintf("%dx%d>", width, height))
  data <- magick::image_write(image, format = "png")
  ellmer::ContentImageInline("image/png", plot_base64_data(data))
}

plot_image_data <- function(path) {
  plot_base64_data(readBin(path, "raw", file.size(path)))
}

plot_base64_data <- function(data) {
  gsub("\n", "", jsonlite::base64_enc(data), fixed = TRUE)
}

render_plot_png <- function(
  plot,
  path,
  width,
  height,
  pixel_ratio,
  call = rlang::caller_env()
) {
  # HTML displays this 2x image at half its pixel dimensions, giving browsers
  # two image pixels per CSS pixel. Scaling resolution too preserves text and
  # point sizes at the logical display size.
  ragg::agg_png(
    path,
    width = width * pixel_ratio,
    height = height * pixel_ratio,
    res = 72 * pixel_ratio,
    scaling = 1.5
  )
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

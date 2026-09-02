is_ggplot <- function(x) {
  inherits(x, "ggplot")
}

render_plot_image <- function(plot, alt) {
  dims <- plot_dimensions()
  path <- tempfile("commons-plot-", fileext = ".svg")
  on.exit(unlink(path), add = TRUE)
  render_plot_svg(plot, path, dims$width, dims$height)
  model <- model_plot_image(path, dims$width, dims$height)
  list(
    model = model,
    html = sprintf(
      paste0(
        "<img class=\"commons-measure-plot\" ",
        "src=\"data:image/svg+xml;base64,%s\" alt=\"%s\"/>"
      ),
      plot_image_data(path),
      html_escape(alt)
    )
  )
}

plot_dimensions <- function() {
  list(width = 768L, height = 512L)
}

model_plot_image <- function(path, width, height) {
  # At 72 DPI, the SVG's points map one-to-one to model image pixels.
  image <- magick::image_read(path, density = 72, strip = TRUE)
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

render_plot_svg <- function(
  plot,
  path,
  width,
  height,
  call = rlang::caller_env()
) {
  # svglite sizes its device in inches and writes the resulting viewBox in points.
  svglite::svglite(
    path,
    width = width / 72,
    height = height / 72,
    scaling = 1.5
  )
  tryCatch(
    print(plot),
    finally = grDevices::dev.off()
  )

  size <- file.size(path)
  if (is.na(size) || size == 0) {
    cli::cli_abort(
      "Plot rendering did not produce an SVG image.",
      call = call
    )
  }
}

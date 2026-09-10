is_ggplot <- function(x) {
  inherits(x, "ggplot")
}

render_plot_image <- function(plot, alt) {
  dims <- plot_dimensions()
  svg_path <- tempfile("commons-plot-", fileext = ".svg")
  png_path <- tempfile("commons-plot-", fileext = ".png")
  on.exit(unlink(c(svg_path, png_path)), add = TRUE)
  recorded <- render_plot_svg(plot, svg_path, dims$width, dims$height)
  path <- svg_path
  # SVG size grows per mark, so bound dense plots with a 2x UI PNG.
  if (file.size(svg_path) > plot_svg_inline_limit()) {
    render_plot_png(
      recorded,
      png_path,
      dims$width,
      dims$height,
      dims$pixel_ratio
    )
    path <- png_path
  }
  # Rasterize the chosen UI artifact so the model sees the same plot layout.
  model <- model_plot_image(path, dims$width, dims$height)
  list(
    model = model,
    html = sprintf(
      paste0(
        "<img class=\"commons-measure-plot\" ",
        "src=\"data:%s;base64,%s\" alt=\"%s\" ",
        "width=\"%d\" height=\"%d\"/>"
      ),
      plot_image_type(path),
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

plot_svg_inline_limit <- function() {
  1024^2
}

model_plot_image <- function(path, width, height) {
  image <- if (identical(plot_image_type(path), "image/svg+xml")) {
    # At 72 DPI, the SVG's points map one-to-one to model image pixels.
    magick::image_read(path, density = 72, strip = TRUE)
  } else {
    magick::image_read(path, strip = TRUE)
  }
  image <- magick::image_resize(image, sprintf("%dx%d>", width, height))
  data <- magick::image_write(image, format = "png")
  ellmer::ContentImageInline("image/png", plot_base64_data(data))
}

plot_image_type <- function(path) {
  if (identical(tolower(tools::file_ext(path)), "svg")) {
    "image/svg+xml"
  } else {
    "image/png"
  }
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
  recorded <- tryCatch(
    {
      # Record once so PNG fallback cannot rebuild a stochastic plot differently.
      grDevices::dev.control(displaylist = "enable")
      print(plot)
      grDevices::recordPlot()
    },
    finally = grDevices::dev.off()
  )

  size <- file.size(path)
  if (is.na(size) || size == 0) {
    cli::cli_abort(
      "Plot rendering did not produce an SVG image.",
      call = call
    )
  }
  recorded
}

render_plot_png <- function(
  plot,
  path,
  width,
  height,
  pixel_ratio,
  call = rlang::caller_env()
) {
  ragg::agg_png(
    path,
    width = width * pixel_ratio,
    height = height * pixel_ratio,
    res = 72 * pixel_ratio,
    scaling = 1.5
  )
  tryCatch(
    grDevices::replayPlot(plot),
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

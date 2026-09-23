is_ggplot <- function(x) {
  inherits(x, "ggplot")
}

render_plot_image <- function(plot, alt) {
  dims <- plot_dimensions()
  paths <- list(
    ui = tempfile("commons-plot-", fileext = ".png"),
    model = tempfile("commons-plot-model-", fileext = ".png")
  )
  on.exit(unlink(unlist(paths)), add = TRUE)
  render_plot_pngs(plot, paths, dims)
  list(
    model = model_plot_image(paths$model),
    html = sprintf(
      paste0(
        "<img class=\"commons-measure-plot\" ",
        "src=\"data:image/png;base64,%s\" alt=\"%s\" ",
        "width=\"%d\" height=\"%d\"/>"
      ),
      plot_image_data(paths$ui),
      html_escape(alt),
      dims$width,
      dims$height
    )
  )
}

plot_dimensions <- function() {
  list(width = 768L, height = 512L, pixel_ratio = 2L)
}

model_plot_image <- function(path) {
  ellmer::ContentImageInline("image/png", plot_image_data(path))
}

plot_image_data <- function(path) {
  plot_base64_data(readBin(path, "raw", file.size(path)))
}

plot_base64_data <- function(data) {
  gsub("\n", "", jsonlite::base64_enc(data), fixed = TRUE)
}

# Renders the UI image at the pixel ratio and the model image at 1x. The model
# image is drawn at its own size rather than downscaled from the UI image, so
# nothing decodes a rendered PNG. The plot is printed once and the recording
# replayed for the model image: printing a ggplot twice would redraw anything
# random, such as geom_jitter(), differently in each image.
render_plot_pngs <- function(plot, paths, dims, call = rlang::caller_env()) {
  open_plot_device(paths$ui, dims, dims$pixel_ratio)
  recording <- tryCatch(
    {
      grDevices::dev.control(displaylist = "enable")
      print(plot)
      grDevices::recordPlot()
    },
    finally = grDevices::dev.off()
  )
  open_plot_device(paths$model, dims, 1L)
  tryCatch(
    grDevices::replayPlot(recording),
    finally = grDevices::dev.off()
  )

  for (path in paths) {
    size <- file.size(path)
    if (is.na(size) || size == 0) {
      cli::cli_abort(
        "Plot rendering did not produce a PNG image.",
        call = call
      )
    }
  }
}

# HTML displays the 2x image at half its pixel dimensions, giving browsers two
# image pixels per CSS pixel. Scaling resolution with the pixel ratio keeps
# text and point sizes at the logical display size, so every image of a plot
# has the same layout.
open_plot_device <- function(path, dims, pixel_ratio) {
  ragg::agg_png(
    path,
    width = dims$width * pixel_ratio,
    height = dims$height * pixel_ratio,
    res = 72 * pixel_ratio,
    scaling = 1.5
  )
}

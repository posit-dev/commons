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

# The 16 MiB cap is well above a full-size plot's PNG.
is_png_data <- function(data, max_bytes = 16 * 1024^2) {
  signature <- as.raw(c(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))
  is.raw(data) &&
    length(data) > length(signature) &&
    length(data) <= max_bytes &&
    identical(data[seq_along(signature)], signature)
}

render_plot_pngs <- function(plot, paths, dims, call = rlang::caller_env()) {
  open_plot_device(paths$ui, dims, dims$pixel_ratio)
  recording <- tryCatch(
    {
      # Replaying one recording, rather than printing twice, keeps random
      # draws like geom_jitter() identical in both images.
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
# image pixels per CSS pixel. Scaling resolution too preserves text and point
# sizes at the logical display size.
open_plot_device <- function(path, dims, pixel_ratio) {
  ragg::agg_png(
    path,
    width = dims$width * pixel_ratio,
    height = dims$height * pixel_ratio,
    res = 72 * pixel_ratio,
    scaling = 1.5
  )
}

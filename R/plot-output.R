is_ggplot <- function(x) {
  inherits(x, "ggplot")
}

render_plot_image <- function(plot, alt) {
  dims <- plot_dimensions()
  base64 <- render_plot_png_base64(plot, dims$width, dims$height)
  list(
    model = ellmer::ContentImageInline(type = "image/png", data = base64),
    html = sprintf(
      paste0(
        "<img class=\"commons-measure-plot\" ",
        "src=\"data:image/png;base64,%s\" alt=\"%s\"/>"
      ),
      base64,
      html_escape(alt)
    )
  )
}

plot_dimensions <- function() {
  list(width = 768L, height = 512L)
}

render_plot_png_base64 <- function(
  plot,
  width,
  height,
  call = rlang::caller_env()
) {
  path <- tempfile("commons-plot-", fileext = ".png")
  on.exit(unlink(path), add = TRUE)

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

  raw <- readBin(path, "raw", size)
  gsub("[[:space:]]+", "", jsonlite::base64_enc(raw))
}

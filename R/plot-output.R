configured_plot_dimensions <- function() {
  plot_dimensions(
    getOption("commons.plot_aspect_ratio", "3:2"),
    getOption("commons.plot_size", 768L)
  )
}

plot_dimensions <- function(ratio, longest_side) {
  parts <- suppressWarnings(
    as.numeric(strsplit(ratio, ":", fixed = TRUE)[[1]])
  )
  r <- if (length(parts) == 2 && all(!is.na(parts) & parts > 0)) {
    parts[[1]] / parts[[2]]
  } else {
    3 / 2
  }
  if (r >= 1) {
    list(
      width = as.integer(round(longest_side)),
      height = as.integer(round(longest_side / r))
    )
  } else {
    list(
      width = as.integer(round(longest_side * r)),
      height = as.integer(round(longest_side))
    )
  }
}

is_ggplot <- function(x) {
  inherits(x, "ggplot")
}

render_plot_image <- function(plot, alt) {
  dims <- configured_plot_dimensions()
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

render_plot_png_base64 <- function(
  plot,
  width,
  height,
  call = rlang::caller_env()
) {
  path <- tempfile("commons-plot-", fileext = ".png")
  on.exit(unlink(path), add = TRUE)

  device <- open_plot_png_device(path, width, height)
  on.exit(close_plot_device(device), add = TRUE)

  print(plot)
  close_plot_device(device)

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

open_plot_png_device <- function(path, width, height) {
  if (requireNamespace("ragg", quietly = TRUE)) {
    previous <- grDevices::dev.list()
    opened <- tryCatch(
      {
        ragg::agg_png(
          path,
          width = width,
          height = height,
          scaling = 1.5
        )
        TRUE
      },
      error = function(error) FALSE
    )
    if (opened) {
      return(grDevices::dev.cur())
    }
    close_new_plot_devices(previous)
  }

  grDevices::png(path, width = width, height = height)
  grDevices::dev.cur()
}

close_new_plot_devices <- function(previous) {
  devices <- grDevices::dev.list()
  if (is.null(devices)) {
    return(invisible())
  }
  previous <- previous %||% integer()
  for (device in rev(setdiff(devices, previous))) {
    try(grDevices::dev.off(device), silent = TRUE)
  }
  invisible()
}

close_plot_device <- function(device) {
  devices <- grDevices::dev.list()
  if (!is.null(devices) && device %in% devices) {
    try(grDevices::dev.off(device), silent = TRUE)
  }
  invisible()
}

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

configured_plot_dimensions <- function(call = rlang::caller_env()) {
  plot_dimensions(
    getOption("commons.plot_aspect_ratio", "3:2"),
    getOption("commons.plot_size", 768L),
    call = call
  )
}

plot_dimensions <- function(
  ratio,
  longest_side,
  call = rlang::caller_env()
) {
  r <- parse_plot_aspect_ratio(ratio, call = call)
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

parse_plot_aspect_ratio <- function(ratio, call = rlang::caller_env()) {
  valid_string <- is.character(ratio) &&
    length(ratio) == 1 &&
    !is.na(ratio)
  parts <- if (valid_string) {
    suppressWarnings(as.numeric(strsplit(ratio, ":", fixed = TRUE)[[1]]))
  } else {
    numeric()
  }
  if (length(parts) == 2 && all(is.finite(parts) & parts > 0)) {
    return(parts[[1]] / parts[[2]])
  }

  value <- paste(deparse(ratio), collapse = "")
  cli::cli_warn(
    c(
      "Invalid {.option commons.plot_aspect_ratio} option.",
      "!" = "Expected a single {.code width:height} string; got {.code {value}}.",
      "i" = "Using {.val 3:2}."
    ),
    call = call
  )
  3 / 2
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

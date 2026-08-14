test_that("plot devices fall back when ragg cannot open", {
  skip_if_not_installed("ragg")
  skip_if_not(capabilities("png"))
  local_mocked_bindings(
    agg_png = function(...) stop("ragg unavailable"),
    .package = "ragg"
  )
  path <- withr::local_tempfile(fileext = ".png")

  device <- open_plot_png_device(path, 320L, 160L)
  withr::defer(close_plot_device(device))
  graphics::plot.new()
  close_plot_device(device)

  expect_gt(file.size(path), 0)
})

test_that("plot dimensions use btw's defaults", {
  expect_equal(
    plot_dimensions(),
    list(width = 768L, height = 512L)
  )
})

test_that("plot rendering rejects an empty PNG", {
  local_mocked_bindings(file.size = function(...) 0, .package = "base")

  expect_snapshot(
    render_plot_png_base64(test_ggplot(), 300L, 200L),
    error = TRUE
  )
})

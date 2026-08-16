test_that("invalid plot aspect ratios warn and use the default", {
  expect_snapshot(plot_dimensions("wide", 300L))
})

test_that("plot dimensions keep the longest side for portrait ratios", {
  expect_equal(
    plot_dimensions("2:3", 300L),
    list(width = 200L, height = 300L)
  )
})

test_that("plot rendering rejects an empty PNG", {
  local_mocked_bindings(file.size = function(...) 0, .package = "base")

  expect_snapshot(
    render_plot_png_base64(test_ggplot(), 300L, 200L),
    error = TRUE
  )
})

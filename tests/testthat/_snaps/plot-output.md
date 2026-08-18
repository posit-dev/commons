# plot rendering rejects an empty PNG

    Code
      render_plot_png_base64(test_ggplot(), 300L, 200L)
    Condition
      Error:
      ! Plot rendering did not produce a PNG image.


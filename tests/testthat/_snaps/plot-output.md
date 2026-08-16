# invalid plot aspect ratios warn and use the default

    Code
      plot_dimensions("wide", 300L)
    Condition
      Warning:
      Invalid commons.plot_aspect_ratio option.
      ! Expected a single `width:height` string; got `"wide"`.
      i Using "3:2".
    Output
      $width
      [1] 300
      
      $height
      [1] 200
      

# plot rendering rejects an empty PNG

    Code
      render_plot_png_base64(test_ggplot(), 300L, 200L)
    Condition
      Error:
      ! Plot rendering did not produce a PNG image.


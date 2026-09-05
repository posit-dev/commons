# trajectory reviewer accepts empty trajectories and rejects other shapes

    Code
      check_trajectories("nope")
    Condition
      Error:
      ! `trajectories` must be a named list of conversations as returned by `trajectory_read()`: each with a `turns` list of <ellmer::Turn>s and a `last_active` <POSIXct>.


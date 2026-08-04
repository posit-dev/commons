# trajectory reviewer accepts empty trajectories and rejects other shapes

    Code
      check_trajectories("nope")
    Condition
      Error:
      ! `trajectories` must be a named list of conversations as returned by `read_trajectories()`: each a list of <ellmer::Turn>s.


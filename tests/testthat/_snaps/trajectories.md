# read_trajectories validates source

    Code
      read_trajectories(1:2)
    Condition
      Error in `read_trajectories()`:
      ! `source` must be `NULL`, a directory path, a Connect content GUID, or a Connect content URL.

# a URL without a recognizable GUID errors rather than reading locally

    Code
      resolve_trajectory_source("https://connect.example.com/other")
    Condition
      Error:
      ! Can't find a content GUID in <https://connect.example.com/other>.
      i Supported URLs contain `/content/<guid>` (a content URL) or `#/apps/<guid>` (a dashboard URL).


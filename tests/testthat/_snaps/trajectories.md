# read_trajectories hints when no conversation carries content

    Code
      .res <- read_trajectories(path)
    Condition
      Warning:
      Found 2 conversations of spans, but none carry message content; returning none.
      i Message content is captured only when the agent runs with `log = TRUE` while OpenTelemetry tracing is active. On Posit Connect, check the app's startup log for warnings from `commons()`.

# read_trajectories drops content-less conversations, keeping the rest

    Code
      .res <- read_trajectories(path)
    Message
      Dropping 1 conversation whose spans carry no message content.

# read_trajectories validates n, from, and to

    Code
      read_trajectories(n = 0)
    Condition
      Error in `read_trajectories()`:
      ! `n` must be a whole number larger than or equal to 1 or `NULL`, not the number 0.

---

    Code
      read_trajectories(n = "x")
    Condition
      Error in `read_trajectories()`:
      ! `n` must be a whole number or `NULL`, not the string "x".

---

    Code
      read_trajectories(from = "not a date")
    Condition
      Error in `read_trajectories()`:
      ! `from` must be a <POSIXct>, a <Date>, or a single datetime string like "2026-07-22 14:30:00".

---

    Code
      read_trajectories(to = 1:2)
    Condition
      Error in `read_trajectories()`:
      ! `to` must be a <POSIXct>, a <Date>, or a single datetime string like "2026-07-22 14:30:00".

---

    Code
      read_trajectories("dir", 5)
    Condition
      Error in `read_trajectories()`:
      ! `...` must be empty.
      x Problematic argument:
      * ..1 = 5
      i Did you forget to name an argument?

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


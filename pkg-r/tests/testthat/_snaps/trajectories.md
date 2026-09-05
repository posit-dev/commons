# trajectory_read hints when no conversation carries content

    Code
      .res <- trajectory_read(path)
    Condition
      Warning:
      Found 2 conversations of spans, but none carry message content; returning none.
      i Message content is captured only when the agent runs with `log = TRUE` while OpenTelemetry tracing is active. On Posit Connect, check the app's startup log for warnings from `commons()`.

# trajectory_read drops content-less conversations, keeping the rest

    Code
      .res <- trajectory_read(path)
    Message
      Dropping 1 conversation whose spans carry no message content.

# trajectory_read validates n, from, and to

    Code
      trajectory_read(n = 0)
    Condition
      Error in `trajectory_read()`:
      ! `n` must be a whole number larger than or equal to 1 or `NULL`, not the number 0.

---

    Code
      trajectory_read(n = "x")
    Condition
      Error in `trajectory_read()`:
      ! `n` must be a whole number or `NULL`, not the string "x".

---

    Code
      trajectory_read(from = "not a date")
    Condition
      Error in `trajectory_read()`:
      ! `from` must be a <POSIXct>, a <Date>, or a single datetime string like "2026-07-22 14:30:00".

---

    Code
      trajectory_read(to = 1:2)
    Condition
      Error in `trajectory_read()`:
      ! `to` must be a <POSIXct>, a <Date>, or a single datetime string like "2026-07-22 14:30:00".

---

    Code
      trajectory_read("dir", 5)
    Condition
      Error in `trajectory_read()`:
      ! `...` must be empty.
      x Problematic argument:
      * ..1 = 5
      i Did you forget to name an argument?

# trajectory_read validates source

    Code
      trajectory_read(1:2)
    Condition
      Error in `trajectory_read()`:
      ! `source` must be `NULL`, a directory path, a Connect content GUID, or a Connect content URL.

# a URL without a recognizable GUID errors rather than reading locally

    Code
      resolve_trajectory_source("https://connect.example.com/other")
    Condition
      Error:
      ! Can't identify Connect content from <https://connect.example.com/other>.
      i Supported URLs contain `/content/<guid>`, `/content/<name>`, or `#/apps/<guid>`.


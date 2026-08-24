# read_measures validates its inputs

    Code
      read_measures(123)
    Condition
      Error in `read_measures()`:
      ! `paths` must be a character vector of file or directory paths.

---

    Code
      read_measures("does-not-exist.R")
    Condition
      Error in `read_measures()`:
      ! Path does not exist: 'does-not-exist.R'.


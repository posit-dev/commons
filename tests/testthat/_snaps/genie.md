# Genie Agent configuration retains no credentials

    Code
      genie_agent("not-an-id")
    Condition
      Error in `genie_agent()`:
      ! `id` must be a 32-character Genie Agent ID.

# Genie parsing is bounded and versions fail closed

    Code
      genie_parse_serialized("{\"version\": 99}")
    Condition
      Error in `genie_parse_serialized()`:
      ! Genie serialized version "99" is not supported.

---

    Code
      genie_parse_serialized(paste0("{\"version\": 2, \"text\": \"", paste(rep("x",
        250001), collapse = ""), "\"}"))
    Condition
      Error in `genie_validate_shape()`:
      ! A string in the serialized Genie Agent exceeds 250 kB.

# Genie permission failures are independent of DBI metadata

    Code
      genie_import(provider, genie_agent("01f190d76f64158d8a1dd3618e1f10d0"), fetch)
    Condition
      Error in `fetch()`:
      ! The REST identity cannot edit this Agent.


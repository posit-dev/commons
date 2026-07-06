# source_describe errors informatively for unknown tables

    Code
      source_describe(test_source(), "nope")
    Condition
      Error in `source_describe()`:
      ! No table named "nope".
      i Available tables: "sales".

# data_source errors for tables absent from the connection

    Code
      data_source(con, tables = "nope")
    Condition
      Error in `data_source()`:
      ! `tables` names table not on the connection: "nope".

# data_source rejects unnamed or non-data-frame input

    Code
      data_source(data.frame(x = 1))
    Condition
      Error in `data_source()`:
      ! All arguments to `data_source()` must be named.

---

    Code
      data_source(a = 1)
    Condition
      Error in `data_source()`:
      ! Every argument must be a data frame; `a` is not.

# data_sources validates its inputs

    Code
      data_sources()
    Condition
      Error in `data_sources()`:
      ! Supply at least one named `data_source()`.

---

    Code
      data_sources(test_source())
    Condition
      Error in `data_sources()`:
      ! All arguments to `data_sources()` must be named.

---

    Code
      data_sources(sales_db = "not a source")
    Condition
      Error in `data_sources()`:
      ! Every argument must be a `data_source()`; `sales_db` is not.

# as_data_sources wraps a bare data_source

    Code
      as_data_sources("nope")
    Condition
      Error:
      ! `data_sources` must be a `data_source()` or `data_sources()`.


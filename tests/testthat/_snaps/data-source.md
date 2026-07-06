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

# as_data_sources validates its input

    Code
      as_data_sources("nope")
    Condition
      Error:
      ! `data_sources` must be a `data_source()` or a named list containing one.

---

    Code
      as_data_sources(list())
    Condition
      Error:
      ! `commons()` currently supports exactly one `data_source()`; `data_sources` has 0.

---

    Code
      as_data_sources(list(sales_db = "not a source"))
    Condition
      Error:
      ! `commons()` currently supports exactly one `data_source()`; `data_sources` has 0.

---

    Code
      as_data_sources(list(test_source(), test_source()))
    Condition
      Error:
      ! `commons()` currently supports exactly one `data_source()`; `data_sources` has 2.

---

    Code
      as_data_sources(list(test_source(), list()))
    Condition
      Error:
      ! Each entry in `data_sources` must be named.

---

    Code
      as_data_sources(list(a = test_source(), a = list()))
    Condition
      Error:
      ! `data_sources` names must be unique; duplicated name: "a".


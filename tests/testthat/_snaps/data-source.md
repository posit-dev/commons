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

# data_source validates board pin names at construction

    Code
      data_source(board, tables = c(orders = "team-orders", missing = "nope"))
    Condition
      Error in `data_source()`:
      ! `tables` names pin not on the board: "nope".

---

    Code
      data_source(board)
    Condition
      Error in `data_source()`:
      ! `tables` must be a named character vector of pin names.

---

    Code
      data_source(board, tables = stats::setNames(character(0), character(0)))
    Condition
      Error in `data_source()`:
      ! `tables` must name at least one pin.

# a pin that isn't a data frame errors clearly

    Code
      source_describe(src, "cfg")
    Condition
      Error in `source_describe()`:
      ! Pin "config" for table "cfg" is not a data frame.
      i It is a list.

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

# resolve_sql_source picks the source for a SQL tool call

    Code
      resolve_sql_source(sources, "nope")
    Condition
      Error:
      ! No data source named "nope".
      i Available sources: "a" and "b".

---

    Code
      resolve_sql_source(sources, NULL)
    Condition
      Error:
      ! `source` is required when an agent has multiple data sources.
      i Available sources: "a" and "b".

# as_data_sources validates its input

    Code
      as_data_sources("nope")
    Condition
      Error:
      ! `data_sources` must be a `data_source()` or a named list of them.

---

    Code
      as_data_sources(list())
    Condition
      Error:
      ! `data_sources` must be a `data_source()` or a named list of them.

---

    Code
      as_data_sources(list(sales_db = "not a source"))
    Condition
      Error:
      ! `data_sources` must be a `data_source()` or a named list of them.

---

    Code
      as_data_sources(list(sales_db = test_source(), board = list()))
    Condition
      Error:
      ! `data_sources` must be a `data_source()` or a named list of them.

---

    Code
      as_data_sources(list(test_source(), test_source()))
    Condition
      Error:
      ! Each entry in `data_sources` must be named.

---

    Code
      as_data_sources(list(a = test_source(), a = test_source()))
    Condition
      Error:
      ! `data_sources` names must be unique; duplicated name: "a".


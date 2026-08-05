# source_describe errors informatively for unknown tables

    Code
      source_describe(test_source(), "nope")
    Condition
      Error in `source_describe()`:
      ! No table named "nope".
      i Available tables: "sales".

# DBI identifiers remain exact rather than patterns

    Code
      normalize_connection_includes(DBI::Id(table = "orders*"))
    Condition
      Error:
      ! Wildcards are not allowed inside <DBI::Id>; put unqualified globs in `exclude`.

# provider identity is checked before every query

    Code
      source_query(source, "SELECT * FROM orders")
    Condition
      Error in `source_query()`:
      ! The connection identity, role, or current namespace changed after catalog discovery; rebuild the data source.

# failed lazy hydration removes the object for the session

    Code
      source_describe(fixture$source, "warehouse_object")
    Condition
      Error in `source_describe()`:
      ! Table "warehouse_object" could not be described.
      Caused by error in `catalog_relation_metadata()`:
      ! permission denied

---

    Code
      source_describe(fixture$source, "warehouse_object")
    Condition
      Error in `source_describe()`:
      ! No table named "warehouse_object".
      i Available tables: .

# catalog providers reject selections above their object bound

    Code
      new_catalog_provider(con, data_source_options())
    Condition
      Error:
      ! The data-source selection resolves to 2 objects, above the supported limit of 1.
      i Narrow `include` to fewer catalog or schema prefixes.

# default connection discovery stays in the current namespace

    Code
      data_source(con)
    Condition
      Error in `data_source()`:
      ! The connection has no current-namespace objects.
      i Set a current catalog/database and schema, or supply `options` with explicit `include` IDs.

# data_source errors for tables absent from the connection

    Code
      source_describe(src, "nope")
    Condition
      Error in `source_describe()`:
      ! Table "nope" could not be described.
      Caused by error in `DBI::dbSendQuery()`:
      ! Catalog Error: Table with name nope does not exist!
      Did you mean "pg_enum"?
      LINE 1: SELECT * FROM nope WHERE 1 = 0
                            ^
      i Context: rapi_prepare
      i Error type: CATALOG

# tables and options cannot be supplied together

    Code
      data_source(orders = data.frame(id = 1), tables = "orders", options = data_source_options(
        include = "orders"))
    Condition
      Error in `data_source()`:
      ! Supply only one of `options` and the deprecated `tables`.

# data_source rejects a board label colliding with a built-in relation

    Code
      data_source(board, tables = c(duckdb_tables = "team-orders"))
    Condition
      Error in `data_source()`:
      ! `tables` label collides with built-in database relation: "duckdb_tables".
      i Rename the affected table.

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
      ! Board data sources require `options` with an explicit `include` mapping.

---

    Code
      data_source(board, tables = stats::setNames(character(0), character(0)))
    Condition
      Error in `data_source()`:
      ! Board `include` must name at least one pin.

# check_board_pins_exist resolves, flags missing, and flags ambiguous names

    Code
      check_board_pins_exist(board, c(x = "nope"))
    Condition
      Error:
      ! `tables` names pin not on the board: "nope".

---

    Code
      check_board_pins_exist(board, c(o = "orders"))
    Condition
      Error:
      ! `tables` names pin matching more than one pin on the board: "orders".
      i Use the full "owner/name" form to disambiguate.

# check_board_pins_exist accepts a pin absent from a capped listing

    Code
      check_board_pins_exist(board, c(x = "nope"))
    Condition
      Error:
      ! `tables` names pin not on the board: "nope".

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


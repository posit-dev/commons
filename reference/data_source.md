# Create a data source

A data source is the set of tables available to a
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
agent.

## Usage

``` r
data_source(..., tables = NULL, dictionary = NULL)
```

## Arguments

- ...:

  A single DBI connection, a single `pins` board, or named data frames
  to register as tables. When passing data frames, each name becomes a
  table name the agent can query.

- tables:

  Which tables to expose, used when a connection or a board is supplied.

  For a connection, a character vector of table names, schema-qualified
  strings like `"schema.table"`, or
  [`DBI::Id`](https://dbi.r-dbi.org/reference/Id.html) objects. Defaults
  to every table returned by
  [`DBI::dbListTables()`](https://dbi.r-dbi.org/reference/dbListTables.html).
  Strings containing dots are interpreted as schema-qualified names; use
  `DBI::Id(table = "a.b")` for literal table names containing dots. For
  Snowflake and Databricks connections, a
  [`DBI::Id`](https://dbi.r-dbi.org/reference/Id.html) ending in
  `catalog` or `schema` selects every table and view in that namespace.
  Leaving `tables` unset selects the current schema. A Databricks
  `hive_metastore` selection must include a schema.

  For a board, a named character vector of pins to read: the names
  become table names, and the values are pin names passed to
  [`pins::pin_read()`](https://pins.rstudio.com/reference/pin_read.html).

- dictionary:

  An optional path to a data dictionary describing the source's tables
  and columns, in the [data-dict.yaml](https://data-dict.tidyverse.org/)
  format. See the `Data dictionaries` section.

## Value

A `commons_data_source` object.

## Details

`data_source()` accepts data in several forms, picked by the class of
what you pass:

- A DBI connection is queried as-is. Nothing is copied; the agent
  queries the database directly.

- Named data frames are loaded into an in-process DuckDB database. Use
  this when the data isn't already in a database.

- A `pins` board, e.g.
  [`pins::board_connect()`](https://pins.rstudio.com/reference/board_connect.html),
  is read into the same in-process database: each pin in `tables`
  becomes a table. Pin names are validated against the board at
  construction (a single listing call), but each pin is downloaded only
  when its table is first used—by the `describe_table` tool, a SQL query
  that references it, or a measure that takes the source's connection.
  [`commons_server()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons_ui.md)
  starts a background process right after startup that downloads the
  remaining pins into the local pins cache, so a first use typically
  only reads an already-downloaded file. A table reflects the pin's
  value at first use and is not refreshed for the lifetime of the data
  source; if a pin can't be read (e.g. a network failure), the error
  surfaces at that first use and the read is retried on the next one.

The resulting object gives the agent a DBI connection plus a table
registry. Use
[`list_tables()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/list_tables.md)
to list the registered tables.

## Data dictionaries

A data dictionary describes a data source's tables and columns: what
each table's rows represent, what its columns mean, allowed values and
units, how tables join, and definitions of domain terms. Its content
reaches the agent three ways:

- The dataset-level `description` and `details`, along with the
  glossary, are included in the system prompt. These fields are the
  place for rules that span tables and for guidance on which tables
  answer which kinds of questions.

- The first time a conversation touches a table—via the `describe_table`
  tool or a SQL query—the table's full dictionary entry rides along with
  the tool result: its prose, documented columns, relationships, and
  definitions of glossary terms it references. `describe_table` merges
  documented columns with the table's live schema.

- For Snowflake and Databricks sources, a fully qualified dictionary
  table name matches the same selected relation. A relative name is
  accepted when it matches only one selected relation. Authored prose
  takes precedence, while warehouse column types remain authoritative.

- When the agent also has a
  [`context_layer()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/context_layer.md),
  the dictionary's prose is indexed for the `search_context` tool.

A table's entry can also declare `definitions`: named, governed SQL
expressions with declared types that the model applies as `{{name}}`
tokens in `run_sql` queries, expanded to their trusted SQL before the
query runs. Definitions are validated against the live source and
delivered through all three channels above.

## Trust

The `run_sql` tool runs only read-only `SELECT` queries; statements that
would modify data or schema (`INSERT`, `UPDATE`, `DROP`, and similar)
are rejected before reaching the database. For the in-process DuckDB
built from data frames, commons additionally disables extension loading
and filesystem access. These are safeguards, not a sandbox: when you
supply your own connection, still open it in read-only mode where the
backend supports it.

## Examples

``` r
src <- data_source(
  sales = data.frame(id = 1:2, revenue = c(100, 200))
)
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/Rtmpezluw6/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
list_tables(src)
#> [1] "sales"
```

# Live warehouse tests

The Snowflake and Databricks smoke tests are opt in. The ordinary test suite
skips them before connecting, so contributors do not need warehouse credentials
or ODBC drivers.

To run the Snowflake test, configure `odbc::snowflake()` with a default
warehouse and set:

```r
options(commons.test.snowflake = DBI::Id(
  catalog = "...",
  schema = "...",
  table = "..."
))
```

To also run the Snowflake semantic-view test, set:

```r
options(commons.test.snowflake.semantic_view = DBI::Id(
  catalog = "...",
  schema = "...",
  table = "..."
))
```

To run the Databricks test, configure an ODBC DSN named `Databricks` and set:

```r
options(commons.test.databricks = DBI::Id(
  catalog = "...",
  schema = "...",
  table = "..."
))
```

Permission tests additionally run when an inaccessible object is configured:

```r
options(
  commons.test.snowflake.denied_table = DBI::Id(
    catalog = "DATABASE",
    schema = "RESTRICTED",
    table = "TABLE"
  ),
  commons.test.databricks.denied_table = DBI::Id(
    catalog = "catalog",
    schema = "restricted",
    table = "table"
  )
)
```

The Snowflake active-role test runs when a second usable role is configured:

```r
options(commons.test.snowflake.alternate_role = "REPORTER")
```

Both warehouse tests exercise exact table selection, schema and catalog
expansion, current-schema discovery, native column metadata, and sample rows.
The Snowflake semantic-view test imports the selected model and executes one of
its public metrics. The Databricks test also uses a temporary view to exercise
quoted relation and column names. If a backend's option is absent, its test
skips. Once enabled, connection and query failures fail the test.

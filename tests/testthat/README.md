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

To run the Databricks test, configure an ODBC DSN named `Databricks` and set:

```r
options(commons.test.databricks = DBI::Id(
  catalog = "...",
  schema = "...",
  table = "..."
))
```

The Snowflake test exercises exact table selection, schema and catalog
expansion, current-schema discovery, native column metadata, and sample rows.
The Databricks test queries the current identity and namespace, then reads at
most one row from the configured table. If a backend's option is absent, its
test skips. Once enabled, connection and query failures fail the test.

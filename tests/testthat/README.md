# Live warehouse tests

The Snowflake and Databricks smoke tests are opt in. The ordinary test suite
skips them before connecting, so contributors do not need warehouse credentials
or ODBC drivers.

To run the Snowflake test, configure `odbc::snowflake()` as usual and set:

```sh
export COMMONS_LIVE_SNOWFLAKE=true
export COMMONS_SNOWFLAKE_DATABASE=...
export COMMONS_SNOWFLAKE_SCHEMA=...
export COMMONS_SNOWFLAKE_TABLE=...
```

To run the Databricks test, configure an ODBC DSN named `Databricks` and set:

```sh
export COMMONS_LIVE_DATABRICKS=true
export COMMONS_DATABRICKS_CATALOG=...
export COMMONS_DATABRICKS_SCHEMA=...
export COMMONS_DATABRICKS_TABLE=...
```

Set `COMMONS_DATABRICKS_DSN` to use a differently named DSN. Identifiers are
passed as separate `catalog`, `schema`, and `table` components of `DBI::Id()`;
do not combine them into a dotted string.

Each test queries the current identity and namespace, constructs a data source
from the structured table identifier, then describes at most one row from that
table. If a live-test switch or identifier is absent, that backend's test skips.
Once enabled, connection and query failures fail the test.

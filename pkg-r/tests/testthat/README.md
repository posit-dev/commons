# Live warehouse tests

The Snowflake and Databricks tests in `test-live-warehouses.R` are opt in. They skip before connecting unless a warehouse is configured, so contributors do not need warehouse credentials or ODBC drivers.

Configure a warehouse with its connection variables. The names are the ones in `tests/shared/live-warehouse-env.json`, which the Python suite reads too, so one export block configures both:

```sh
export SNOWFLAKE_ACCOUNT=myorg-myaccount
export SNOWFLAKE_USER=MY_USER
export SNOWFLAKE_WAREHOUSE=MY_WH
export SNOWFLAKE_PRIVATE_KEY_FILE=~/.snowflake/keys/rsa_key.p8

export DATABRICKS_HOST=https://example.cloud.databricks.com
export DATABRICKS_HTTP_PATH=/sql/1.0/warehouses/abc123
```

You can also keep the variables in a `.env` file at the repository root, which git ignores. To start one, copy `.env.example` from the repository root to `.env`; it lists every variable and shows the format the file needs. `devtools::test()` reads it with `readRenviron()` for the length of the run, and a variable already set in the environment wins over it. `tests/shared/live-warehouse-env.json` lists the rules both suites follow under `env_file`.

Snowflake signs in with a key pair registered to `SNOWFLAKE_USER`. `odbc::databricks()` finds Databricks credentials in the environment: `DATABRICKS_TOKEN`, a service principal's `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`, or a `databricks auth login` session. Both need the vendor's ODBC driver.

Create the tables, the denied table, the semantic models, and the second Snowflake role with `scripts/provision-live-warehouse.py`; `pkg-py/tests/README.md` describes it. Their names are fixed in `tests/shared/live-warehouse-env.json`, and the tests read them from there.

Once a backend is configured, connection and query failures fail its tests.

`.github/workflows/R-live-warehouse.yaml` runs these tests in CI, in the same GitHub environments as the Python live tests. [The Python test README](../../../pkg-py/tests/README.md#running-the-live-tests-in-ci) describes how to configure them.

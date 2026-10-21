# Live warehouse tests

The Snowflake and Databricks tests in `test-live-warehouses.R` are opt in. They skip before connecting unless a warehouse is configured, so contributors do not need warehouse credentials or ODBC drivers.

Configure a warehouse with environment variables. The names are the ones in `tests/shared/live-warehouse-env.json`, which the Python suite reads too, so one export block configures both:

```sh
export SNOWFLAKE_ACCOUNT=myorg-myaccount
export SNOWFLAKE_USER=MY_USER
export SNOWFLAKE_WAREHOUSE=MY_WH
export SNOWFLAKE_PRIVATE_KEY_FILE=~/.snowflake/keys/rsa_key.p8
export COMMONS_TEST_SNOWFLAKE_SCHEMA=COMMONS_CI.PUBLIC

export DATABRICKS_HOST=https://example.cloud.databricks.com
export DATABRICKS_HTTP_PATH=/sql/1.0/warehouses/abc123
export COMMONS_TEST_DATABRICKS_SCHEMA=main.commons_live
```

Snowflake signs in with a key pair registered to `SNOWFLAKE_USER`. `odbc::databricks()` finds Databricks credentials in the environment: `DATABRICKS_TOKEN`, a service principal's `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`, or a `databricks auth login` session. Both need the vendor's ODBC driver.

Create the tables with `scripts/provision-live-warehouse.py`; `pkg-py/tests/README.md` describes it. The R tests use its `orders` table.

The optional variables in the contract each enable more tests: a denied table for the permission tests, a second Snowflake role for the active-role test, and semantic views or metric views for the semantic-model tests. A parameterized model also needs its arguments as a JSON object:

```sh
export COMMONS_TEST_SNOWFLAKE_PARAMETERIZED_MODEL=ANALYTICS.PUBLIC.SALES_MODEL
export COMMONS_TEST_SNOWFLAKE_PARAMETERIZED_MODEL_ARGUMENTS='{"threshold": 100}'
```

Once a backend is configured, connection and query failures fail its tests.

`.github/workflows/R-live-warehouse.yaml` runs these tests in CI, with credentials from the repository's `databricks-ci` and `snowflake-ci` environments.

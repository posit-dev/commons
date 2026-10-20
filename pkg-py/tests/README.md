# Running the tests

`uv run pytest` runs everything. Nothing here needs credentials: a test that
cannot reach what it needs skips.

## Live warehouse tests

`test_live_warehouses.py` runs against a real Snowflake or Databricks and
skips without one. It exists because every other warehouse test drives a fake
replaying canned rows, which cannot tell us what a warehouse actually returns.

Install the drivers, which are deliberately outside the `dev` group so an
ordinary contributor does not install a warehouse client:

```
uv sync --group live-warehouse
```

Point at a warehouse. The connection variables are the vendor's own, so one
export block also serves the vendor CLIs and the R suite:

```
export DATABRICKS_HOST=https://example.cloud.databricks.com
export DATABRICKS_HTTP_PATH=/sql/1.0/warehouses/abc123
export COMMONS_TEST_DATABRICKS_SCHEMA=main.commons_live

export SNOWFLAKE_ACCOUNT=myorg-myaccount
export SNOWFLAKE_USER=MY_USER
export SNOWFLAKE_WAREHOUSE=MY_WH
export SNOWFLAKE_PRIVATE_KEY_FILE=~/.snowflake/keys/rsa_key.p8
export COMMONS_TEST_SNOWFLAKE_SCHEMA=COMMONS_CI.PUBLIC
```

Databricks credentials come from the SDK's
[unified authentication](https://docs.databricks.com/aws/en/dev-tools/auth/unified-auth):
`DATABRICKS_TOKEN`, a service principal's `DATABRICKS_CLIENT_ID` and
`DATABRICKS_CLIENT_SECRET`, or a `databricks auth login` session. Snowflake
signs in with a key pair registered to `SNOWFLAKE_USER`.
`tests/shared/live-warehouse-env.json` is the full list of variables,
including the optional ones that gate individual tests.

Create the tables the tests expect:

```
python3 ../scripts/provision-live-warehouse.py databricks main.commons_live
```

That prints SQL to run; it does not connect. The rows come from
`tests/shared/live-warehouse-rows.json`, and the same file is loaded into
DuckDB so the two engines' answers can be compared.

One fixture it cannot create is the denied table, since an owner can always
read their own relation. Making one needs a second principal, and the
generated SQL says what is left to do. Until its variable is set, the
access-refusal test skips.

`test_live_warehouse_fixture.py` covers the half of this that needs no
warehouse: the rows load, every corpus definition runs against them, and the
provisioning SQL renders. It runs in CI with the rest of the suite.
`.github/workflows/py-live-warehouse.yaml` runs the live tests themselves,
with credentials from the repository's `databricks-ci` and `snowflake-ci`
environments, and skips a backend whose environment is not configured.

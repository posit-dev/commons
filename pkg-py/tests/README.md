# Running the tests

`uv run pytest` runs everything. Nothing here needs credentials: a test that
cannot reach what it needs skips.

## Live warehouse tests

`test_live_warehouses.py` runs against a real Snowflake or Databricks and
skips without one. Every other warehouse test drives a fake replaying canned
rows, which cannot tell us what a warehouse actually returns. Setting up for
the live tests takes three steps.

### 1. Install the drivers

The drivers are deliberately outside the `dev` group so an ordinary
contributor does not install a warehouse client:

```
uv sync --group live-warehouse
```

### 2. Export the connection variables

The variables are the vendor's own, so the same export block works for the
vendor CLIs and the R suite:

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

### 3. Create the fixture tables

```
python3 ../scripts/provision-live-warehouse.py databricks main.commons_live
```

This command prints the SQL needed to initialize the live warehouse for the test
suite. It does not connect to the warehouse or run anything directly.
You will need to paste the output into a Databricks
SQL editor or Snowflake worksheet and run it there. The rows come from
`tests/shared/live-warehouse-rows.json`, and the same file is loaded into
DuckDB so the two engines' answers can be compared.

The access-refusal test needs a table the test principal cannot read, so this
step involves two principals. The test principal is the one behind the
connection variables from step 2: on Snowflake, the role the `SNOWFLAKE_USER`
connects with; on Databricks, the application ID of the service principal the
credentials resolve to (`DATABRICKS_CLIENT_ID`, when the credential is a
service principal). Pass that principal to `--grant-to`, and the SQL grants
it the fixture tables plus a copy of one it gets no grant on.

The second principal is whoever runs that SQL (the user or admin): it
is simply the identity you are signed in as in the SQL editor. It must differ
from the test principal, because an owner can always read its own tables; if
the test principal runs the SQL, it owns the copy and nothing is refused. The
output ends by naming the variable to export with the copy's identifier
(`COMMONS_TEST_DATABRICKS_DENIED_TABLE` or
`COMMONS_TEST_SNOWFLAKE_DENIED_TABLE`), and the access-refusal test skips
until it is set. Without `--grant-to` the SQL creates no denied table at all.

With those done, `uv run pytest` runs the live tests along with everything
else. `test_live_warehouse_fixture.py` covers the half of this that needs no
warehouse: the rows load, every corpus definition runs against them, and the
provisioning SQL renders. It runs in CI with the rest of the suite.
`.github/workflows/py-live-warehouse.yaml` runs the live tests themselves,
with credentials from the repository's `databricks-ci` and `snowflake-ci`
environments, and skips a backend whose environment is not configured.

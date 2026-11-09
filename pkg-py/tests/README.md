# Running the tests

`uv run pytest` runs everything. Nothing here needs credentials: a test that cannot reach what it needs skips.

## Live warehouse tests

`test_live_warehouses.py` runs against a real Snowflake or Databricks and skips without one. Every other warehouse test drives a fake replaying canned rows, which cannot tell us what a warehouse actually returns. Setting up for the live tests takes three steps.

### 1. Install the drivers

The drivers are in the `dev` group, so `uv sync` installs them.

### 2. Set the connection variables

The variables are the vendor's own, so the same export block works for the vendor CLIs and the R suite:

```
export DATABRICKS_HOST=https://example.cloud.databricks.com
export DATABRICKS_HTTP_PATH=/sql/1.0/warehouses/abc123

export SNOWFLAKE_ACCOUNT=myorg-myaccount
export SNOWFLAKE_USER=MY_USER
export SNOWFLAKE_WAREHOUSE=MY_WH
export SNOWFLAKE_PRIVATE_KEY_FILE=~/.snowflake/keys/rsa_key.p8
```

You can also keep the variables in a `.env` file at the repository root, which git ignores. To start one, copy `.env.example` from the repository root to `.env`; it lists every variable and shows the format the file needs. The tests read it with python-dotenv when you run them from a checkout, and a variable already set in the environment wins over it. `tests/shared/live-warehouse-env.json` lists the rules both suites follow under `env_file`.

Databricks credentials come from the SDK's [unified authentication](https://docs.databricks.com/aws/en/dev-tools/auth/unified-auth): `DATABRICKS_TOKEN`, a service principal's `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`, or a `databricks auth login` session. The tests request only the `sql` scope, so a client secret scoped to `sql` works. Snowflake signs in with a key pair registered to `SNOWFLAKE_USER`. `tests/shared/live-warehouse-env.json` is the full list of variables.

### 3. Create the fixture objects

```
python3 ../scripts/provision-live-warehouse.py databricks <application-id>
python3 ../scripts/provision-live-warehouse.py snowflake <role>
```

Each command prints the SQL that creates everything the live tests use: the fixture tables, a table the test principal cannot read, the semantic models, and on Snowflake a second role. The schema and object names are fixed in `tests/shared/live-warehouse-env.json` (`workspace.commons_live` on Databricks, `COMMONS_CI.LIVE` on Snowflake), and the tests read them from there, so a test fails when its object is missing. The script does not connect to the warehouse or run anything directly. You will need to paste the output into a Databricks SQL editor or Snowflake worksheet and run it there. The rows come from `tests/shared/live-warehouse-rows.json`, and the same file is loaded into DuckDB so the two engines' answers can be compared.

The access-refusal test needs a table the test principal cannot read, so this step involves two principals. The test principal is the one behind the connection variables from step 2: on Snowflake, the role the `SNOWFLAKE_USER` connects with; on Databricks, the application ID of the service principal the credentials resolve to (`DATABRICKS_CLIENT_ID`, when the credential is a service principal). Pass that principal as the second argument, and the SQL grants it the fixture tables and models plus a copy of one table it gets no grant on. Everyone shares the one schema, and the SQL drops and recreates the fixture tables, which removes the grants of any principal it does not name. Pass the principal CI connects as, so that a run does not lock CI out of the fixtures.

The second principal is the one that runs the SQL, and it owns the copy. On Databricks, that is the identity you are signed in as in the SQL editor. On Snowflake, it is the worksheet's active role, so run the SQL under a role other than the test role, even when you sign in as a different user. An owner can always read its own tables, so if the test principal owns the copy, nothing is refused. The Snowflake SQL also creates the second role the active-role test switches to, so run it under a role that can create roles as well as the schema's objects, such as `ACCOUNTADMIN`. `USERADMIN` cannot create the tables, and `SYSADMIN` cannot create the role.

With those done, `uv run pytest` runs the live tests along with everything else. `test_live_warehouse_fixture.py` covers the half of this that needs no warehouse: the rows load, every corpus definition runs against them, and the provisioning SQL renders. It runs in CI with the rest of the suite. `.github/workflows/py-live-warehouse.yaml` runs the live tests themselves.

## Running the live tests in CI

Each backend runs in its own GitHub environment, named in the workflow's matrix. To configure an environment:

1. Add each value from step 2 as an environment variable, except `SNOWFLAKE_PRIVATE_KEY_FILE`.
2. For Snowflake, add the private key text as the secret `SNOWFLAKE_PRIVATE_KEY`. The workflow writes it to a file and sets `SNOWFLAKE_PRIVATE_KEY_FILE`.
3. For Databricks, add `DATABRICKS_CLIENT_ID` as a variable and the client secret as the secret `DATABRICKS_CLIENT_SECRET`.

To use GitHub OIDC for Databricks instead, do not set the client secret. Then give the service principal a federation policy that accepts GitHub tokens for the subject `repo:posit-dev/commons:environment:<name>`. Set `DATABRICKS_TOKEN_AUDIENCE` only if the policy expects an audience other than the token endpoint of the workspace.

A backend with no variables set skips. A backend with only some of the required variables set fails, so a configuration error cannot pass by skipping every test.

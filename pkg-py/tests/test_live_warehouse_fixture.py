"""The live-warehouse fixture, checked without a warehouse.

The tests in `test_live_warehouses.py` skip unless one is configured, which
would leave the rows, the DuckDB loader and the provisioning SQL unexercised
in CI until someone with credentials ran them. These tests cover that half:
the rows load, every corpus definition runs against them, and the generator
renders. What is left needing a real warehouse is only what a warehouse can
answer.
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from tests._live_warehouse import comparable, duckdb_fixture_connection, matches
from tests._shared import SHARED_DIR, load_shared_fixture
from tests.test_definition_emit_sql import compile_corpus

ROWS = load_shared_fixture("live-warehouse-rows")
ROWS_UNRUNNABLE = {key for key in ROWS["unrunnable"] if key != "note"}


def _generator() -> SimpleNamespace:
    """The provisioning script, loaded from the repository root.

    Read and executed rather than imported, because importing it writes a
    __pycache__ into scripts/, and a test should not leave anything behind in
    a directory of shell scripts.
    """
    path = Path(SHARED_DIR).parents[1] / "scripts" / "provision-live-warehouse.py"
    namespace: dict[str, object] = {"__file__": str(path), "__name__": "provisioner"}
    exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), namespace)  # noqa: S102
    return SimpleNamespace(**namespace)


def test_the_fixture_tables_are_the_ones_the_corpus_dictionaries_describe():
    """The rows exist to make the corpus definitions runnable.

    A column added to a dictionary without being added here would leave a
    definition referring to something the provisioned table lacks, which
    would only surface as a live failure on someone else's machine.
    """
    import yaml

    from commons._data_dictionary import DataDictionary

    for table, spec in ROWS["tables"].items():
        path = SHARED_DIR / "definition-export" / "valid" / spec["dictionary"]
        dictionary = DataDictionary.model_validate(
            yaml.safe_load(path.read_text(encoding="utf-8"))
        )
        assert table in dictionary.tables, spec["dictionary"]
        authored = set(dictionary.tables[table].columns)
        provisioned = {column["name"] for column in spec["columns"]}
        assert authored == provisioned, (
            f"{table}: dictionary has {sorted(authored - provisioned)} that the "
            f"fixture rows lack, and {sorted(provisioned - authored)} the "
            "dictionary does not describe"
        )


def test_the_rows_load_into_duckdb_with_their_declared_types():
    con = duckdb_fixture_connection()

    for table, spec in ROWS["tables"].items():
        rows = con.execute(f'SELECT * FROM "{table}"').fetchall()
        assert len(rows) == len(spec["rows"])
        assert len(rows) > 5, (
            f"{table} needs more than five rows, so describe_table's sample "
            "cap is exercised rather than assumed"
        )


def test_every_corpus_definition_runs_against_the_fixture_rows():
    """The DuckDB half of the live comparison, which needs no warehouse.

    A definition that cannot run here would fail live for a reason that has
    nothing to do with the warehouse, so this is where that is caught.
    """
    con = duckdb_fixture_connection()

    mixed_grain = load_shared_fixture("definitions")["mixed_grain"]
    unrunnable = set(ROWS_UNRUNNABLE)

    checked = 0
    expected = 0
    for table, spec in ROWS["tables"].items():
        grain = mixed_grain[spec["dictionary"]]
        compiled = compile_corpus(spec["dictionary"], "duckdb")
        table_keys = [key for key in compiled if key.startswith(f"{table}::")]
        expected += sum(
            1 for key in table_keys if not grain.get(key) and key not in unrunnable
        )
        for key, record in compiled.items():
            if not key.startswith(f"{table}::"):
                continue
            # A mixed-grain definition projects a row-shaped expression over an
            # aggregate, so no engine can run it as a bare selection. commons'
            # own guard refuses it, and `definitions.json` is where that
            # classification lives.
            if grain.get(key) or key in unrunnable:
                continue
            rows = con.execute(
                f'SELECT {record.sql} AS result FROM "{table}"'
            ).fetchall()
            assert rows, key
            checked += 1
    assert checked == expected, (
        f"{expected - checked} definitions were dropped without being "
        "exempted in the fixture"
    )
    assert checked > 35, f"only {checked} definitions ran"


PROVISIONED = {
    backend: spec["provisioned"]
    for backend, spec in load_shared_fixture("live-warehouse-env")["backends"].items()
}


@pytest.mark.parametrize("dialect", ["databricks", "snowflake"])
def test_the_provisioning_script_renders_every_fixture_table(dialect):
    sql = _generator().render(dialect, "tester")

    for table in ROWS["tables"]:
        assert "CREATE TABLE" in sql and table in sql
    assert sql.count("INSERT INTO") == len(ROWS["tables"])
    # The rows carry doubles JSON cannot spell, and the literal for them is
    # per-dialect, so an unrendered one would reach the warehouse as a string.
    for literal in _generator().SPECIAL_DOUBLES[dialect].values():
        assert literal in sql, literal


def test_every_databricks_table_maps_columns_by_name():
    # A fixture name with a space, like survey's `nick names` struct field,
    # fails CREATE TABLE on Delta without column mapping.
    sql = _generator().render("databricks", "tester")

    assert sql.count("'delta.columnMapping.mode' = 'name'") == len(ROWS["tables"])


@pytest.mark.parametrize("dialect", ["databricks", "snowflake"])
def test_the_grants_cover_every_fixture_relation_but_the_denied_one(dialect):
    generator = _generator()
    names = PROVISIONED[dialect]
    sql = generator.render(dialect, "tester")
    granted = [line for line in sql.splitlines() if line.startswith("GRANT SELECT")]
    relations = list(ROWS["tables"])
    if dialect == "databricks":
        relations.append(names["parameterized_model"])

    assert len(granted) == len(relations)
    for relation in relations:
        assert any(
            generator.quote_identifier(relation, dialect) in line for line in granted
        )
    denied = generator.quote_identifier(names["denied_table"], dialect)
    assert not any(denied in line for line in granted)
    assert f".{denied} AS SELECT" in sql


def test_every_semantic_view_the_tests_name_is_provisioned_on_snowflake():
    generator = _generator()
    names = PROVISIONED["snowflake"]
    sql = generator.render("snowflake", "tester")
    namespace = ".".join(f'"{part}"' for part in names["namespace"])

    for fixture in ("semantic_view", "verified_query_view", "parameterized_model"):
        assert names[fixture] in generator.SEMANTIC_VIEWS
    for view in generator.SEMANTIC_VIEWS:
        assert f"name: {view}\n" in sql
        assert f'SEMANTIC VIEW {namespace}."{view}" TO ROLE' in sql
    # Snowflake folds an unquoted variable name to upper case, as the
    # arguments spell it.
    for argument in names["parameterized_model_arguments"]:
        assert f"- name: {argument}\n" in sql
    assert "SEMANTIC VIEW" not in generator.render("databricks", "tester")


def test_the_snowflake_test_role_can_assume_the_alternate_role():
    role = PROVISIONED["snowflake"]["alternate_role"]
    sql = _generator().render("snowflake", "tester")

    assert f'CREATE ROLE IF NOT EXISTS "{role}";' in sql
    assert f'GRANT ROLE "{role}" TO ROLE "tester";' in sql


def test_the_parameterized_metric_view_is_provisioned_on_databricks():
    names = PROVISIONED["databricks"]
    sql = _generator().render("databricks", "tester")
    namespace = ".".join(f"`{part}`" for part in names["namespace"])

    assert f"VIEW {namespace}.`{names['parameterized_model']}`\nWITH METRICS" in sql
    for argument in names["parameterized_model_arguments"]:
        assert f"- name: {argument}\n" in sql


def test_a_semantic_view_escapes_the_namespace_for_yaml_alone():
    sql = "\n".join(_generator().semantic_views(["O'Brien", "schema"]))

    assert "database: '\"O''Brien\"'" in sql
    assert 'FROM "O\'Brien"."schema"."orders"' in sql


def test_a_mismatch_is_reported_as_one():
    """The comparator, since every live assertion rests on it."""
    assert matches([1.0, None], [None, 1.0])
    assert matches([float("nan")], [float("nan")])
    assert not matches([1.0], [1.0, 2.0])
    assert not matches([1.0], [2.0])
    assert comparable(True) is True

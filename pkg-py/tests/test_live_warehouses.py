"""What only a real warehouse can tell us.

Everything else in this suite that touches Snowflake or Databricks runs
against a fake replaying canned rows, so it checks how commons reads a
listing rather than what a warehouse returns. These tests assert the things
the fake cannot answer: the row shapes the listing queries really produce,
how a genuine refusal is reported, what the session identity queries say,
and whether the SQL the definition emitters produce both parses and computes
what DuckDB computes for the same rows.

Every test skips unless the backend is configured. See
`tests/_live_warehouse.py` for the variables and
`scripts/provision-live-warehouse.py` for the tables.
"""

from __future__ import annotations

import pytest

from commons._backends import EngineBackend
from commons._catalog import (
    CatalogAuthorizationError,
    Selector,
    _databricks,
    _snowflake,
    normalize_identifier,
    require_queryable,
    session_snapshot,
)
from commons._catalog._security import probe_relation
from commons._data_source import TableId, data_source, list_tables
from tests._live_warehouse import (
    duckdb_fixture_connection,
    matches,
    require_live_warehouse,
)
from tests._shared import load_shared_fixture
from tests.test_definition_emit_sql import compile_corpus

ROWS_UNRUNNABLE = {
    key
    for key in load_shared_fixture("live-warehouse-rows")["unrunnable"]
    if key != "note"
}

BACKENDS = ["databricks", "snowflake"]
FIXTURE_TABLES = ["orders", "values", "survey"]

_READERS = {"databricks": _databricks, "snowflake": _snowflake}
_CASE = {"databricks": "lower", "snowflake": "upper"}


def _backend(live) -> EngineBackend:
    return EngineBackend(live.engine)


def _selector(live) -> Selector:
    return Selector(catalog=live.namespace[0], schema=live.namespace[1])


def _folded(live, name: str) -> str:
    return normalize_identifier(name, _CASE[live.backend])


@pytest.mark.parametrize("backend", BACKENDS)
def test_the_listing_reports_the_provisioned_relations(backend):
    live = require_live_warehouse(backend)
    reader = _READERS[backend]

    relations = reader.list_relations(_backend(live), _selector(live))

    listed = {_folded(live, relation.id.table) for relation in relations}
    assert {_folded(live, table) for table in FIXTURE_TABLES} <= listed
    for relation in relations:
        assert relation.kind in ("table", "view")


@pytest.mark.parametrize("backend", BACKENDS)
def test_the_listing_rows_carry_the_keys_the_shared_fixture_pins(backend):
    """The shape of a real reply, against the shape the fixture claims.

    `tests/shared/catalog-rows.json` was written from documentation rather
    than from a captured reply, so this is the test that turns it from
    plausible into checked. Extra keys are allowed, since a warehouse may add
    columns to its own listing; a missing one means the fixture is wrong.
    """
    live = require_live_warehouse(backend)
    pinned = load_shared_fixture("catalog-rows")[backend]
    catalog, schema = live.namespace
    backend_obj = _backend(live)

    if backend == "databricks":
        relation_rows = backend_obj.query(
            "SELECT * FROM system.information_schema.tables "
            f"WHERE table_catalog = '{catalog}' AND table_schema = '{schema}'"
        )
        column_rows = backend_obj.query(f"DESCRIBE TABLE {live.dotted('survey')}")
    else:
        relation_rows = backend_obj.query(
            f'SHOW OBJECTS IN SCHEMA "{catalog}"."{schema}"'
        )
        column_rows = backend_obj.query(f"DESC TABLE {live.dotted('survey')}")

    for group, rows in (("relations", relation_rows), ("columns", column_rows)):
        assert rows, f"{backend} returned no {group}"
        expected = set(pinned[group]["rows"][0])
        actual = {str(key).lower() for key in rows[0]}
        assert expected <= actual, (
            f"{backend} {group} rows are missing {sorted(expected - actual)}; "
            "tests/shared/catalog-rows.json describes a shape this warehouse "
            "does not return"
        )


@pytest.mark.parametrize("backend", BACKENDS)
def test_a_source_over_the_namespace_describes_every_fixture_table(backend):
    live = require_live_warehouse(backend)

    source = data_source(live.engine, tables=_selector(live))

    labels = {_folded(live, label) for label in list_tables(source)}
    assert {_folded(live, table) for table in FIXTURE_TABLES} <= labels
    survey = next(
        label
        for label in list_tables(source)
        if _folded(live, label).endswith("survey")
    )
    assert source.relations is not None
    columns = source.relations[survey].columns
    described = {
        str(column.get("col_name") or column.get("name")).lower() for column in columns
    }
    authored = {
        column["name"]
        for column in load_shared_fixture("live-warehouse-rows")["tables"]["survey"][
            "columns"
        ]
    }
    assert authored <= described


@pytest.mark.parametrize("backend", BACKENDS)
def test_the_session_snapshot_reads_the_live_identity(backend):
    live = require_live_warehouse(backend)

    snapshot = session_snapshot(_backend(live))

    assert snapshot is not None
    assert snapshot.principal
    # Databricks has no role, which is why `catalog-session-changed.json`
    # pins which fields each backend can report as changed at all.
    if backend == "databricks":
        assert snapshot.role is None
    assert snapshot.catalog and snapshot.schema


@pytest.mark.parametrize("backend", BACKENDS)
def test_a_refusal_is_classified_as_authorization(backend):
    """What a real permission error says, against what the fixture assumed.

    `tests/shared/catalog-access-errors.json` decides from a driver's
    SQLSTATE and message whether commons caches the refusal or retries, and
    its cases were written from documentation. A refusal this test cannot
    classify is a defect in that file, not in the warehouse.
    """
    live = require_live_warehouse(backend, "denied_table")
    denied = TableId(*live.fixtures["denied_table"].split("."))
    backend_obj = _backend(live)

    probe = probe_relation(backend_obj, denied)

    assert probe.state == "authorization", (
        f"a real {backend} refusal classified as {probe.state!r}: {probe.error}"
    )
    with pytest.raises(CatalogAuthorizationError):
        require_queryable(backend_obj, denied, denied.label)


@pytest.mark.parametrize("backend", BACKENDS)
def test_the_emitted_definition_sql_agrees_with_duckdb(backend):
    """Every corpus definition, run on the warehouse and on DuckDB.

    This is what a live run is for. `definition-warehouse-sql.json` pins SQL
    no warehouse has ever parsed, so running it proves the syntax; comparing
    the values against DuckDB over the same rows proves the emitter did not
    merely produce valid SQL for the wrong computation.

    A definition whose record carries notes is exempt from the comparison and
    only has to execute. The notes are where an emitter records a deliberate
    divergence from data-dict's semantics (trim, LIKE escaping, regex
    dialect), so they name exactly the cases whose answers are expected to
    differ. Reading the exemption off the notes rather than off a list here
    means a divergence cannot be claimed without also being documented.
    """
    live = require_live_warehouse(backend)
    duckdb_con = duckdb_fixture_connection()
    rows_fixture = load_shared_fixture("live-warehouse-rows")
    backend_obj = _backend(live)

    mixed_grain = load_shared_fixture("definitions")["mixed_grain"]
    unrunnable = set(ROWS_UNRUNNABLE)

    compared = 0
    executed = 0
    for table, spec in rows_fixture["tables"].items():
        warehouse_records = compile_corpus(spec["dictionary"], backend)
        duckdb_records = compile_corpus(spec["dictionary"], "duckdb")
        grain = mixed_grain[spec["dictionary"]]
        for key, record in warehouse_records.items():
            if not key.startswith(f"{table}::"):
                continue
            # Projecting a row-shaped expression over an aggregate is what
            # commons' own grain guard refuses, so no engine can run it as a
            # bare selection and there is nothing to compare.
            if grain.get(key) or key in unrunnable:
                continue
            warehouse_values = [
                next(iter(row.values()))
                for row in backend_obj.query(
                    f"SELECT {record.sql} AS result FROM {live.dotted(table)}"
                )
            ]
            executed += 1
            if record.notes:
                continue
            expected = [
                row[0]
                for row in duckdb_con.execute(
                    f'SELECT {duckdb_records[key].sql} AS result FROM "{table}"'
                ).fetchall()
            ]
            assert matches(warehouse_values, expected), (
                f"{key} on {backend} returned {warehouse_values!r}, DuckDB "
                f"returned {expected!r}, and the record documents no divergence"
            )
            compared += 1

    assert executed, "no definitions were executed"
    assert compared, "every definition was exempted, so nothing was compared"

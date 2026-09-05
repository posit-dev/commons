"""Session and access checks for a warehouse catalog.

A fake backend stands in for the network here, not for a warehouse's access
rules: the point of each test is what commons does with the reply, since the
warehouse is the one deciding whether a principal may read a relation.
"""

from typing import Any

import pytest

from commons._catalog import Manifest, Relation
from commons._catalog._security import (
    CatalogAccessError,
    CatalogAuthorizationError,
    CatalogSessionChangedError,
    CatalogTransientError,
    SessionSnapshot,
    check_session,
    classify_access_error,
    ensure_queryable,
    probe_relation,
    require_queryable,
    require_queryable_relations,
    session_snapshot,
)
from commons._data_source import TableId


class DriverError(Exception):
    """An error carrying a SQLSTATE, the way a warehouse driver's does."""

    def __init__(self, message, sqlstate=None):
        super().__init__(message)
        self.sqlstate = sqlstate


class FakeBackend:
    """Replays a canned reply, or raises, for each query it is given."""

    def __init__(self, replies=None, dialect="snowflake", exists=None):
        self._replies = list(replies or [])
        self._dialect = dialect
        self._exists = exists
        self.queries: list[str] = []

    def query(self, sql: str):
        self.queries.append(sql)
        reply = self._replies.pop(0) if self._replies else []
        if isinstance(reply, BaseException):
            raise reply
        return reply

    def quote(self, table_id: TableId) -> str:
        return ".".join(f'"{part}"' for part in table_id.parts)

    def dialect(self) -> str:
        return self._dialect

    def inspector(self):
        if self._exists is None:
            return None
        return lambda table_id: self._exists


SALES = TableId(catalog="ANALYTICS", schema="PUBLIC", table="SALES")


def snowflake_row(role="REPORTER") -> dict[str, Any]:
    return {
        "PRINCIPAL": "ANALYST",
        "ROLE": role,
        "SECONDARY_ROLES": '{"roles":"READER","value":"ALL"}',
        "CATALOG": "ANALYTICS",
        "SCHEMA": "PUBLIC",
    }


def test_session_snapshots_retain_authority_bearing_fields():
    backend = FakeBackend([[snowflake_row()]])

    snapshot = session_snapshot(backend)

    assert snapshot == SessionSnapshot(
        backend="snowflake",
        principal="ANALYST",
        role="REPORTER",
        secondary_roles='{"roles":"READER","value":"ALL"}',
        catalog="ANALYTICS",
        schema="PUBLIC",
    )


def test_databricks_snapshots_carry_no_role():
    rows = [
        [{"principal": "analyst@example.com", "catalog": "main", "schema": "default"}]
    ]
    backend = FakeBackend(rows, dialect="databricks")

    snapshot = session_snapshot(backend)

    assert snapshot is not None
    assert snapshot.role is None
    assert snapshot.secondary_roles is None
    assert (snapshot.catalog, snapshot.schema) == ("main", "default")


def test_other_backends_have_no_session_to_snapshot():
    assert session_snapshot(FakeBackend(dialect="duckdb")) is None


def test_an_empty_session_value_is_absent_rather_than_blank():
    row = snowflake_row()
    row["ROLE"] = ""
    row["SCHEMA"] = None

    snapshot = session_snapshot(FakeBackend([[row]]))

    assert snapshot is not None
    assert snapshot.role is None
    assert snapshot.schema is None


def test_an_unreadable_session_identity_is_an_error():
    backend = FakeBackend([DriverError("connection closed")])

    with pytest.raises(RuntimeError, match="session identity"):
        session_snapshot(backend)


def test_an_invalid_session_reply_is_an_error():
    with pytest.raises(ValueError, match="invalid session identity"):
        session_snapshot(FakeBackend([[]]))

    with pytest.raises(ValueError, match="invalid session identity"):
        session_snapshot(FakeBackend([[{"PRINCIPAL": "ANALYST"}]]))


def test_catalog_operations_reject_a_changed_session():
    taken = session_snapshot(FakeBackend([[snowflake_row()]]))
    backend = FakeBackend([[snowflake_row(role="ADMIN")]])

    with pytest.raises(CatalogSessionChangedError, match="active role changed"):
        check_session(backend, taken)


def test_a_databricks_refusal_never_names_a_role():
    rows = {"principal": "analyst@example.com", "catalog": "main", "schema": "default"}
    taken = session_snapshot(FakeBackend([[rows]], dialect="databricks"))
    assert taken is not None
    moved = FakeBackend([[{**rows, "principal": "other@example.com"}]], "databricks")

    with pytest.raises(CatalogSessionChangedError) as refusal:
        check_session(moved, taken)

    assert "principal changed" in str(refusal.value)
    assert "role" not in str(refusal.value)


def test_an_unchanged_session_passes():
    taken = session_snapshot(FakeBackend([[snowflake_row()]]))
    backend = FakeBackend([[snowflake_row()]])

    check_session(backend, taken)


def test_a_source_without_a_session_is_not_checked():
    backend = FakeBackend()

    check_session(backend, None)

    assert backend.queries == []


def test_a_probe_reads_no_rows_from_the_relation():
    backend = FakeBackend()

    probe = probe_relation(backend, SALES)

    assert probe.state == "queryable"
    assert backend.queries == ['SELECT * FROM "ANALYTICS"."PUBLIC"."SALES" WHERE 1 = 0']


def test_require_queryable_names_the_relation_it_refused():
    backend = FakeBackend([DriverError("hidden", sqlstate="42501")])

    with pytest.raises(CatalogAuthorizationError, match="ANALYTICS.PUBLIC.SALES"):
        require_queryable(backend, SALES)


def test_transient_access_failures_remain_retryable():
    relations = {"sales": Relation(id=SALES)}
    manifest = Manifest.build(relations)
    backend = FakeBackend([DriverError("timed out"), []])

    with pytest.raises(CatalogTransientError):
        ensure_queryable(backend, manifest, "sales", SALES)
    assert manifest.access["sales"] == "unknown"

    ensure_queryable(backend, manifest, "sales", SALES)
    assert manifest.access["sales"] == "queryable"
    assert len(backend.queries) == 2


def test_authorization_failures_are_cached_per_relation():
    relations = {"sales": Relation(id=SALES)}
    manifest = Manifest.build(relations)
    backend = FakeBackend([DriverError("permission denied")])

    for _ in range(2):
        with pytest.raises(CatalogAuthorizationError):
            ensure_queryable(backend, manifest, "sales", SALES)

    assert manifest.access["sales"] == "authorization"
    assert len(backend.queries) == 1


def test_a_relation_already_known_queryable_is_not_probed_again():
    manifest = Manifest.build({"sales": Relation(id=SALES)})
    manifest.access["sales"] = "queryable"
    backend = FakeBackend()

    ensure_queryable(backend, manifest, "sales", SALES)

    assert backend.queries == []


def test_a_source_without_a_manifest_has_nothing_to_check():
    backend = FakeBackend()

    ensure_queryable(backend, None, "sales", SALES)

    assert backend.queries == []


def test_exact_relations_use_classified_access_probes():
    backend = FakeBackend([DriverError("warehouse is starting")])

    with pytest.raises(CatalogTransientError):
        require_queryable_relations(backend, {"ANALYTICS.PUBLIC.SALES": SALES})


def test_an_undiscovered_relation_fails_before_the_access_probe():
    backend = FakeBackend()
    relations = {"ANALYTICS.PUBLIC.SALES": Relation(id=SALES, discovered=False)}

    with pytest.raises(ValueError, match="must not name"):
        require_queryable_relations(
            backend, {"ANALYTICS.PUBLIC.SALES": SALES}, relations
        )

    assert backend.queries == []


def test_an_unexplained_failure_on_an_absent_relation_reports_it_missing():
    backend = FakeBackend([DriverError("object not found")], exists=False)

    with pytest.raises(ValueError, match="must not name"):
        require_queryable_relations(backend, {"ANALYTICS.PUBLIC.SALES": SALES})


def test_an_unexplained_failure_is_kept_when_the_relation_is_there():
    backend = FakeBackend([DriverError("something odd")], exists=True)

    with pytest.raises(CatalogAccessError, match="Could not verify"):
        require_queryable_relations(backend, {"ANALYTICS.PUBLIC.SALES": SALES})


def test_a_backend_that_cannot_answer_existence_keeps_the_access_error():
    backend = FakeBackend([DriverError("something odd")])

    with pytest.raises(CatalogAccessError, match="Could not verify"):
        require_queryable_relations(backend, {"ANALYTICS.PUBLIC.SALES": SALES})


def test_a_relation_the_listing_reported_is_probed_even_beside_a_missing_one():
    orders = TableId(catalog="ANALYTICS", schema="PUBLIC", table="ORDERS")
    backend = FakeBackend([DriverError("permission denied")])
    relations = {
        "ANALYTICS.PUBLIC.SALES": Relation(id=SALES, discovered=False),
        "ANALYTICS.PUBLIC.ORDERS": Relation(id=orders),
    }

    with pytest.raises(ValueError, match="ANALYTICS.PUBLIC.SALES"):
        require_queryable_relations(
            backend,
            {"ANALYTICS.PUBLIC.SALES": SALES, "ANALYTICS.PUBLIC.ORDERS": orders},
            relations,
        )

    # The refused relation was still probed, so fixing the missing name is
    # not a round trip spent to be told about the next problem.
    assert len(backend.queries) == 1


def test_a_missing_relation_is_reported_alongside_a_refused_one():
    orders = TableId(catalog="ANALYTICS", schema="PUBLIC", table="ORDERS")
    backend = FakeBackend(
        [DriverError("object not found"), DriverError("permission denied")],
        exists=False,
    )

    with pytest.raises(ValueError, match="ANALYTICS.PUBLIC.SALES"):
        require_queryable_relations(
            backend,
            {"ANALYTICS.PUBLIC.SALES": SALES, "ANALYTICS.PUBLIC.ORDERS": orders},
        )


def test_a_failing_existence_check_keeps_the_access_error():
    backend = FakeBackend([DriverError("something odd")])
    backend.inspector = lambda: _raise_on_call

    with pytest.raises(CatalogAccessError, match="Could not verify"):
        require_queryable_relations(backend, {"ANALYTICS.PUBLIC.SALES": SALES})


def _raise_on_call(table_id):
    raise DriverError("the inspector failed too")


def test_a_chained_driver_error_still_yields_its_sqlstate():
    inner = DriverError("hidden", sqlstate="42501")
    outer = Exception("statement failed")
    outer.__cause__ = inner

    assert classify_access_error(outer) == "authorization"

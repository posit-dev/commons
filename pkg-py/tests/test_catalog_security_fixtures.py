"""Access-error classification and session comparison, against the shared
fixtures.

Which failures are authorization, transient, or neither decides what the user
is told and whether the answer is cached, and which parts of a session are
reported as changed decides what they are told to look at, so both are pinned
once and read by both suites.
"""

import pytest

from commons._catalog import Relation
from commons._catalog._security import (
    CatalogAccessError,
    CatalogAuthorizationError,
    CatalogTransientError,
    SessionSnapshot,
    changed_session_fields,
    classify_access_error,
    require_queryable_relations,
)
from commons._data_source import TableId
from tests._shared import load_shared_fixture


class DriverError(Exception):
    def __init__(self, message, sqlstate):
        super().__init__(message)
        self.sqlstate = sqlstate


def test_access_errors_match_the_shared_contract():
    cases = load_shared_fixture("catalog-access-errors")["cases"]
    assert cases

    for case in cases:
        error = DriverError(case["message"], case["sqlstate"] or None)
        assert classify_access_error(error) == case["kind"], case["name"]


def test_changed_session_fields_match_the_shared_contract():
    cases = load_shared_fixture("catalog-session-changed")["cases"]
    assert cases

    for case in cases:
        before, after = _snapshot(case["before"]), _snapshot(case["after"])
        assert changed_session_fields(after, before) == case["changed"], case["name"]


def _snapshot(fields):
    return SessionSnapshot(
        backend=fields["backend"],
        principal=fields["principal"],
        catalog=fields["catalog"],
        schema=fields["schema"],
        role=fields["role"],
        secondary_roles=fields["secondary_roles"],
    )


class _PrecedenceBackend:
    """Answers each relation's probe from the fixture's own script."""

    def __init__(self, relations):
        self._script = {item["label"]: item for item in relations}
        self.probed: list[str] = []

    def query(self, sql: str):
        label = sql.split('"')[1]
        self.probed.append(label)
        state = self._script[label]["probe"]
        if state == "queryable":
            return []
        raise _PROBE_ERRORS[state]()

    def quote(self, table_id):
        return f'"{table_id.table}"'

    def dialect(self):
        return "snowflake"

    def inspector(self):
        def exists(table_id):
            answer = self._script[table_id.table].get("exists", "unknown")
            if answer == "unknown":
                raise RuntimeError("the backend cannot say")
            return answer == "true"

        return exists


_PROBE_ERRORS = {
    "authorization": lambda: DriverError("permission denied", None),
    "transient": lambda: DriverError("timed out", None),
    "unknown": lambda: DriverError("something odd", None),
}

_OUTCOMES = {
    "missing": ValueError,
    "authorization": CatalogAuthorizationError,
    "transient": CatalogTransientError,
    "access": CatalogAccessError,
}


def test_access_precedence_matches_the_shared_contract():
    cases = load_shared_fixture("catalog-access-precedence")["cases"]
    assert cases

    for case in cases:
        backend = _PrecedenceBackend(case["relations"])
        validate = {
            item["label"]: TableId(table=item["label"]) for item in case["relations"]
        }
        relations = {
            item["label"]: Relation(
                id=validate[item["label"]], discovered=item["discovered"] == "true"
            )
            for item in case["relations"]
        }
        expected = case["expected"]
        if expected["outcome"] == "ok":
            require_queryable_relations(backend, validate, relations)
        else:
            with pytest.raises(_OUTCOMES[expected["outcome"]]) as refusal:
                require_queryable_relations(backend, validate, relations)
            for label in expected["labels"]:
                assert label in str(refusal.value), case["name"]
        # The contract is that nothing is raised until every relation the
        # listing reported has been probed, which only the probes can show.
        assert backend.probed == [
            item["label"] for item in case["relations"] if item["discovered"] == "true"
        ], case["name"]

"""Access-error classification and session comparison, against the shared
fixtures.

Which failures are authorization, transient, or neither decides what the user
is told and whether the answer is cached, and which parts of a session are
reported as changed decides what they are told to look at, so both are pinned
once and read by both suites.
"""

import functools

import pytest
import sqlalchemy.exc

from commons._catalog import Relation, Selector, table_registry
from commons._catalog import _databricks as databricks
from commons._catalog import _snowflake as snowflake
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
        assert classify_access_error(_driver_error(case)) == case["kind"], case["name"]


def _driver_error(case):
    error = DriverError(case["message"], case["sqlstate"] or None)
    if not case.get("sql"):
        return error
    # SQLAlchemy repeats the statement back in the wrapper it raises, which
    # is how the probe's own relation name reaches the classifier.
    return sqlalchemy.exc.ProgrammingError(case["sql"], {}, error)


def test_changed_session_fields_match_the_shared_contract():
    cases = load_shared_fixture("catalog-session-changed")["cases"]
    assert cases

    for case in cases:
        before, after = _snapshot(case["before"]), _snapshot(case["after"])
        assert before is not None, case["name"]
        assert changed_session_fields(after, before) == case["changed"], case["name"]


def _snapshot(fields):
    # A null case is a connection that reports no session at all.
    if fields is None:
        return None
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
            # The exact class, not a base one: an authorization refusal and an
            # unexplained failure are both CatalogAccessError, and the fixture
            # is pinning which of the two the caller gets.
            assert type(refusal.value) is _OUTCOMES[expected["outcome"]], case["name"]
            for label in expected["labels"]:
                assert label in str(refusal.value), case["name"]
        # The contract is that nothing is raised until every relation the
        # listing reported has been probed, which only the probes can show.
        assert backend.probed == [
            item["label"] for item in case["relations"] if item["discovered"] == "true"
        ], case["name"]


class _LabelBackend:
    """A Snowflake connection whose listing answers from the fixture case."""

    def __init__(self, namespace, reported):
        self._namespace = namespace
        self._reported = reported

    def query(self, sql: str):
        if "CURRENT_DATABASE" in sql:
            return [
                {
                    "catalog": self._namespace["catalog"],
                    "schema": self._namespace["schema"],
                }
            ]
        if self._reported is None:
            return []
        return [
            {
                "name": self._reported["table"],
                "kind": "TABLE",
                "database_name": self._reported["catalog"],
                "schema_name": self._reported["schema"],
                "comment": None,
            }
        ]

    def dialect(self):
        return "snowflake"


class _HiveLabelBackend:
    """A Databricks connection whose `SHOW TABLES` answers from the case.

    Only this reply can report a relation with no namespace of its own, which
    is what a session-scoped temporary view is.
    """

    def __init__(self, namespace, reported):
        self._namespace = namespace
        self._reported = reported

    def query(self, sql: str):
        if "CURRENT_CATALOG" in sql:
            return [dict(self._namespace)]
        if self._reported is None:
            return []
        temporary = bool(self._reported.get("temporary"))
        return [
            {
                "database": "" if temporary else self._namespace["schema"],
                "tableName": self._reported["table"],
                "isTemporary": temporary,
            }
        ]

    def dialect(self):
        return "databricks"


_LABEL_BACKENDS = {
    "snowflake": (_LabelBackend, snowflake.exact_relation),
    "databricks": (_HiveLabelBackend, databricks.exact_relation),
}


def test_relation_labels_match_the_shared_contract():
    cases = load_shared_fixture("catalog-relation-labels")["cases"]
    assert cases

    for case in cases:
        authored = case["authored"]
        connection, exact_relation = _LABEL_BACKENDS[case["backend"]]
        backend = connection(case["namespace"], case["reported"])
        registry = table_registry(
            selectors=[
                Selector(
                    catalog=authored.get("catalog"),
                    schema=authored.get("schema"),
                    table=authored["table"],
                )
            ],
            exact_relation=functools.partial(exact_relation, backend),
            list_relations=lambda selector: [],
        )

        assert list(registry.relations) == [case["label"]], case["name"]
        # The access check pairs the two lists by label, so a selection entry
        # has to be validated under the label it ended up with.
        assert list(registry.validate) == [case["label"]], case["name"]

        identity = registry.relations[case["label"]].identity
        assert (identity.label if identity else None) == case["identity"], case["name"]
        assert registry.relations[case["label"]].discovered is (
            case["reported"] is not None
        ), case["name"]

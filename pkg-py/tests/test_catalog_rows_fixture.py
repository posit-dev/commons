"""Both backends' row interpretation, against the shared fixture.

Which rows are relations, what kind each is, which comments count as prose,
and where a DESCRIBE reply stops being columns are all user-observable, so
they are pinned once and read by both suites rather than asserted twice.
"""

from commons._catalog._databricks import (
    columns_from_describe,
    relations_from_information_schema,
)
from commons._catalog._snowflake import columns_from_desc, relations_from_show
from tests._shared import load_shared_fixture

# Booleans travel as strings so the fixture reads the same in R, where a bare
# JSON true would arrive as a logical and an absent one as NULL.
_BOOLEANS = {"true": True, "false": False}


def _expected_description(value: str) -> str | None:
    return value or None


def _check_relations(actual, expected, label):
    assert len(actual) == len(expected), label
    for relation, case in zip(actual, expected):
        assert relation.id.catalog == case["catalog"], label
        assert relation.id.schema == case["schema"], label
        assert relation.id.table == case["table"], label
        assert relation.kind == case["kind"], label
        assert relation.description == _expected_description(case["description"])


def _check_columns(actual, expected, label):
    assert len(actual) == len(expected), label
    for column, case in zip(actual, expected):
        assert column["column"] == case["column"], label
        assert column["type"] == case["type"], label
        assert column["nullable"] is _BOOLEANS[case["nullable"]], label
        assert column["description"] == _expected_description(case["description"])


def test_snowflake_rows_match_the_shared_contract():
    fixture = load_shared_fixture("catalog-rows")["snowflake"]
    _check_relations(
        relations_from_show(fixture["relations"]["rows"]),
        fixture["relations"]["expected"],
        "snowflake relations",
    )
    _check_columns(
        columns_from_desc(fixture["columns"]["rows"]),
        fixture["columns"]["expected"],
        "snowflake columns",
    )


def test_databricks_rows_match_the_shared_contract():
    fixture = load_shared_fixture("catalog-rows")["databricks"]
    _check_relations(
        relations_from_information_schema(fixture["relations"]["rows"]),
        fixture["relations"]["expected"],
        "databricks relations",
    )
    nullable = {
        name: _BOOLEANS[value] for name, value in fixture["columns"]["nullable"].items()
    }
    _check_columns(
        columns_from_describe(fixture["columns"]["rows"], nullable),
        fixture["columns"]["expected"],
        "databricks columns",
    )


def test_the_fixture_covers_both_backends():
    fixture = load_shared_fixture("catalog-rows")
    for backend in ("snowflake", "databricks"):
        assert fixture[backend]["relations"]["rows"], backend
        assert fixture[backend]["columns"]["rows"], backend

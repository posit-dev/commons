"""Reading a Snowflake catalog.

The queries are separated from the interpretation of their rows, which is
what makes this testable without a warehouse: the row readers are pure, and
the query builders are checked by recording the SQL they send. A fake
connection here stands in for a network, not for Snowflake's semantics; the
row shapes are taken from real `SHOW OBJECTS` and `DESC TABLE` output.
"""

import pytest

from commons._catalog import Selector
from commons._catalog._snowflake import (
    SHOW_ROW_LIMIT,
    check_show_complete,
    columns_from_desc,
    current_namespace,
    describe_relation,
    exact_relation,
    is_snowflake,
    list_relations,
    relations_from_show,
)


class FakeBackend:
    """Records the SQL it is asked to run and replays canned rows."""

    def __init__(self, rows=None, dialect="snowflake"):
        self._rows = rows if rows is not None else []
        self._dialect = dialect
        self.queries: list[str] = []

    def query(self, sql: str):
        self.queries.append(sql)
        return self._rows

    def dialect(self) -> str:
        return self._dialect


def show_rows():
    return [
        {
            "name": "Sales.Report",
            "database_name": "Data.Base",
            "schema_name": "Odd Schema",
            "kind": "VIEW",
            "comment": "A useful view",
        },
        {
            "name": "ORDERS",
            "database_name": "ANALYTICS",
            "schema_name": "PUBLIC",
            "kind": "TABLE",
            "comment": "",
        },
        {
            "name": "STAGE",
            "database_name": "ANALYTICS",
            "schema_name": "PUBLIC",
            "kind": "STAGE",
            "comment": "Ignored",
        },
    ]


# --- backend detection -----------------------------------------------------


def test_a_snowflake_dialect_is_recognised():
    assert is_snowflake(FakeBackend()) is True
    assert is_snowflake(FakeBackend(dialect="duckdb")) is False


# --- SHOW OBJECTS ----------------------------------------------------------


def test_only_tables_and_views_become_relations():
    relations = relations_from_show(show_rows())
    assert [item.id.table for item in relations] == ["Sales.Report", "ORDERS"]


def test_a_relation_keeps_its_three_part_identity():
    first = relations_from_show(show_rows())[0]
    assert first.id.catalog == "Data.Base"
    assert first.id.schema == "Odd Schema"
    assert first.id.table == "Sales.Report"
    # A dot inside a component is data, not a separator.
    assert first.id.label == "Data.Base.Odd Schema.Sales.Report"


def test_a_relation_kind_is_lowercased():
    assert relations_from_show(show_rows())[0].kind == "view"


def test_a_blank_comment_is_no_description():
    relations = relations_from_show(show_rows())
    assert relations[0].description == "A useful view"
    assert relations[1].description is None


def test_column_names_are_read_case_insensitively():
    # Snowflake returns upper-case column names over some drivers.
    rows = [
        {
            "NAME": "ORDERS",
            "DATABASE_NAME": "ANALYTICS",
            "SCHEMA_NAME": "PUBLIC",
            "KIND": "TABLE",
            "COMMENT": None,
        }
    ]
    assert relations_from_show(rows)[0].id.table == "ORDERS"


def test_no_rows_is_no_relations():
    assert relations_from_show([]) == []


def test_a_full_page_of_results_is_refused_as_possibly_truncated():
    with pytest.raises(ValueError, match="truncated"):
        check_show_complete([{}] * SHOW_ROW_LIMIT, "relations")


def test_a_partial_page_is_accepted():
    assert check_show_complete([{}], "relations") is None


# --- DESC TABLE ------------------------------------------------------------


def desc_rows():
    return [
        {
            "name": "AMOUNT",
            "type": "NUMBER(38,2)",
            "kind": "COLUMN",
            "null?": "Y",
            "comment": "Warehouse amount description.",
        },
        {
            "name": "ORDER_ID",
            "type": "NUMBER(38,0)",
            "kind": "COLUMN",
            "null?": "N",
            "comment": "",
        },
        {
            "name": "SOMETHING",
            "type": "TEXT",
            "kind": "EXPRESSION",
            "null?": "Y",
            "comment": "Not a column",
        },
    ]


def test_only_column_rows_describe_a_relation():
    assert [row["column"] for row in columns_from_desc(desc_rows())] == [
        "AMOUNT",
        "ORDER_ID",
    ]


def test_nullability_reads_the_null_flag():
    columns = columns_from_desc(desc_rows())
    assert columns[0]["nullable"] is True
    assert columns[1]["nullable"] is False


def test_a_blank_column_comment_is_no_description():
    columns = columns_from_desc(desc_rows())
    assert columns[0]["description"] == "Warehouse amount description."
    assert columns[1]["description"] is None


# --- the queries -----------------------------------------------------------


def test_listing_a_schema_scopes_to_that_schema():
    backend = FakeBackend(rows=show_rows())
    list_relations(backend, Selector(catalog="ANALYTICS", schema="PUBLIC"))
    assert backend.queries == ['SHOW OBJECTS IN SCHEMA "ANALYTICS"."PUBLIC"']


def test_listing_a_database_scopes_to_that_database():
    backend = FakeBackend(rows=show_rows())
    list_relations(backend, Selector(catalog="ANALYTICS"))
    assert backend.queries == ['SHOW OBJECTS IN DATABASE "ANALYTICS"']


def test_listing_a_schema_without_a_catalog_uses_the_current_database():
    backend = FakeBackend(rows=show_rows())
    list_relations(backend, Selector(schema="PUBLIC"))
    assert backend.queries == ['SHOW OBJECTS IN SCHEMA "PUBLIC"']


def test_a_quote_inside_an_identifier_is_doubled():
    backend = FakeBackend(rows=[])
    list_relations(backend, Selector(catalog='we"ird'))
    assert backend.queries == ['SHOW OBJECTS IN DATABASE "we""ird"']


def test_an_exact_relation_is_matched_by_name_within_its_schema():
    backend = FakeBackend(rows=show_rows())
    found = exact_relation(
        backend, Selector(catalog="ANALYTICS", schema="PUBLIC", table="ORDERS")
    )
    assert backend.queries == [
        'SHOW OBJECTS LIKE \'ORDERS\' IN SCHEMA "ANALYTICS"."PUBLIC"'
    ]
    assert found is not None
    # The label keeps what was asked for; the warehouse identity is retained.
    assert found.id.label == "ANALYTICS.PUBLIC.ORDERS"
    assert found.identity is not None


def test_an_exact_relation_the_warehouse_does_not_have_is_not_found():
    backend = FakeBackend(rows=[])
    found = exact_relation(
        backend, Selector(catalog="ANALYTICS", schema="PUBLIC", table="ABSENT")
    )
    assert found is None


def test_a_bare_table_is_looked_up_in_the_current_namespace():
    """A selector naming only a table resolves against the connection.

    Without this test, deleting the current-namespace fallback fails
    nothing: the recording fake accepts the malformed query, and the name
    filter still matches the canned rows.
    """

    class NamespaceBackend(FakeBackend):
        def query(self, sql: str):
            rows = super().query(sql)
            if sql.startswith("SELECT CURRENT"):
                return [{"catalog": "ANALYTICS", "schema": "PUBLIC"}]
            return rows

    backend = NamespaceBackend(rows=show_rows())
    found = exact_relation(backend, Selector(table="ORDERS"))
    assert backend.queries == [
        "SELECT CURRENT_DATABASE() AS catalog, CURRENT_SCHEMA() AS schema",
        'SHOW OBJECTS LIKE \'ORDERS\' IN SCHEMA "ANALYTICS"."PUBLIC"',
    ]
    assert found is not None
    assert found.id.label == "ANALYTICS.PUBLIC.ORDERS"


def test_describing_a_relation_quotes_its_full_path():
    backend = FakeBackend(rows=desc_rows())
    from commons._data_source import TableId

    describe_relation(
        backend, TableId(catalog="ANALYTICS", schema="PUBLIC", table="ORDERS")
    )
    assert backend.queries == ['DESC TABLE "ANALYTICS"."PUBLIC"."ORDERS"']


def test_the_current_namespace_comes_from_the_connection():
    backend = FakeBackend(rows=[{"catalog": "ANALYTICS", "schema": "PUBLIC"}])
    assert current_namespace(backend) == Selector(catalog="ANALYTICS", schema="PUBLIC")


def test_a_connection_with_no_current_namespace_is_refused():
    # Nothing to import, and guessing a database would be worse than failing.
    backend = FakeBackend(rows=[{"catalog": None, "schema": "PUBLIC"}])
    with pytest.raises(ValueError, match="no current database and schema"):
        current_namespace(backend)


def test_an_unexpected_namespace_reply_is_refused():
    backend = FakeBackend(rows=[])
    with pytest.raises(ValueError, match="invalid current namespace"):
        current_namespace(backend)


def test_a_near_match_from_a_case_insensitive_like_is_not_accepted():
    """`SHOW OBJECTS LIKE` ignores case, so the reply is filtered by name.

    Asking for ORDERS and getting back `orders` means the warehouse has a
    differently-cased table, not the one that was named. Returning it would
    quietly bind the selection to a different relation.
    """
    backend = FakeBackend(
        rows=[
            {
                "name": "orders",
                "database_name": "ANALYTICS",
                "schema_name": "PUBLIC",
                "kind": "TABLE",
                "comment": None,
            }
        ]
    )
    found = exact_relation(
        backend, Selector(catalog="ANALYTICS", schema="PUBLIC", table="ORDERS")
    )
    assert found is None


def test_a_capped_exact_lookup_is_refused_rather_than_reported_absent():
    """A full page from `SHOW OBJECTS LIKE` may have dropped the match.

    R checks this only when listing a namespace, not on the exact lookup.
    This diverges deliberately: without it a capped reply reports the table
    as absent, which is a wrong answer rather than a loud one. The case is
    vanishingly rare, since it needs a schema holding a page-full of
    case-variant names, and failing loudly is the cheaper direction.
    """
    row = {
        "name": "orders",
        "database_name": "ANALYTICS",
        "schema_name": "PUBLIC",
        "kind": "TABLE",
        "comment": None,
    }
    backend = FakeBackend(rows=[row] * SHOW_ROW_LIMIT)
    with pytest.raises(ValueError, match="truncated"):
        exact_relation(
            backend, Selector(catalog="ANALYTICS", schema="PUBLIC", table="ORDERS")
        )

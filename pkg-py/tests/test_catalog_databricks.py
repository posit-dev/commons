"""Reading a Databricks catalog.

Same split as the Snowflake reader: pure row interpretation, plus query
builders checked by recording the SQL they send. Row shapes come from real
`system.information_schema.tables`, `SHOW TABLES` and `DESCRIBE TABLE`
output.
"""

import pytest

from commons._catalog import Selector
from commons._catalog._databricks import (
    columns_from_describe,
    current_namespace,
    describe_relation,
    exact_relation,
    is_databricks,
    list_relations,
    relations_from_information_schema,
)
from commons._data_source import TableId


class FakeBackend:
    """Replays a reply per query, and records what it was asked."""

    def __init__(self, replies=None, dialect="databricks"):
        self._replies = list(replies or [])
        self._dialect = dialect
        self.queries: list[str] = []

    def query(self, sql: str):
        self.queries.append(sql)
        return self._replies.pop(0) if self._replies else []

    def dialect(self) -> str:
        return self._dialect


def unity_rows():
    return [
        {
            "table_catalog": "main",
            "table_schema": "sales",
            "table_name": "orders",
            "table_type": "MANAGED",
            "comment": "Booked sales.",
        },
        {
            "table_catalog": "main",
            "table_schema": "sales",
            "table_name": "orders_view",
            "table_type": "VIEW",
            "comment": "",
        },
    ]


def describe_rows():
    return [
        {"col_name": "amount", "data_type": "decimal(38,2)", "comment": "Money."},
        {"col_name": "order_id", "data_type": "bigint", "comment": ""},
        {"col_name": "", "data_type": "", "comment": ""},
        {"col_name": "# Partition Information", "data_type": "", "comment": ""},
        {"col_name": "part_col", "data_type": "string", "comment": "Not a column."},
    ]


# --- backend detection -----------------------------------------------------


def test_a_databricks_dialect_is_recognised():
    assert is_databricks(FakeBackend()) is True
    assert is_databricks(FakeBackend(dialect="duckdb")) is False


# --- information_schema listing --------------------------------------------


def test_relations_carry_their_three_part_identity():
    relations = relations_from_information_schema(unity_rows())
    assert [item.id.label for item in relations] == [
        "main.sales.orders",
        "main.sales.orders_view",
    ]


def test_a_view_is_distinguished_from_a_table():
    relations = relations_from_information_schema(unity_rows())
    assert [item.kind for item in relations] == ["table", "view"]


def test_a_blank_comment_is_no_description():
    relations = relations_from_information_schema(unity_rows())
    assert relations[0].description == "Booked sales."
    assert relations[1].description is None


def test_listing_a_schema_filters_by_catalog_and_schema():
    backend = FakeBackend(replies=[unity_rows()])
    list_relations(backend, Selector(catalog="main", schema="sales"))
    sql = backend.queries[0]
    assert "system.information_schema.tables" in sql
    assert "table_catalog = 'main'" in sql
    assert "table_schema = 'sales'" in sql


def test_the_information_schema_itself_is_never_listed():
    backend = FakeBackend(replies=[unity_rows()])
    list_relations(backend, Selector(catalog="main", schema="sales"))
    assert "table_schema <> 'information_schema'" in backend.queries[0]


def test_listing_a_catalog_does_not_filter_by_schema():
    backend = FakeBackend(replies=[unity_rows()])
    list_relations(backend, Selector(catalog="main"))
    assert "table_schema = " not in backend.queries[0]


def test_a_quote_inside_a_name_is_escaped():
    backend = FakeBackend(replies=[[]])
    list_relations(backend, Selector(catalog="it's", schema="sales"))
    assert "table_catalog = 'it''s'" in backend.queries[0]


# --- hive_metastore --------------------------------------------------------


def test_the_legacy_metastore_is_listed_with_show_tables():
    # system.information_schema does not expose hive_metastore tables.
    backend = FakeBackend(replies=[[{"tablename": "legacy"}]])
    relations = list_relations(
        backend, Selector(catalog="hive_metastore", schema="default")
    )
    assert backend.queries == ["SHOW TABLES IN `hive_metastore`.`default`"]
    assert [item.id.label for item in relations] == ["hive_metastore.default.legacy"]


def test_the_legacy_metastore_needs_a_schema():
    backend = FakeBackend()
    with pytest.raises(ValueError, match="schema"):
        list_relations(backend, Selector(catalog="hive_metastore"))


# --- DESCRIBE TABLE --------------------------------------------------------


def test_describe_stops_at_the_metadata_section():
    """`DESCRIBE TABLE` appends partition and detail sections after a `#` row.

    Reading past it turns section headings into columns.
    """
    columns = columns_from_describe(describe_rows())
    assert [row["column"] for row in columns] == ["amount", "order_id"]


def test_a_blank_column_comment_is_no_description():
    columns = columns_from_describe(describe_rows())
    assert columns[0]["description"] == "Money."
    assert columns[1]["description"] is None


def test_nullability_comes_from_the_information_schema():
    columns = columns_from_describe(
        describe_rows(), {"amount": True, "order_id": False}
    )
    assert columns[0]["nullable"] is True
    assert columns[1]["nullable"] is False


def test_nullability_is_unknown_when_it_was_not_read():
    # hive_metastore has no information_schema to ask.
    columns = columns_from_describe(describe_rows(), {})
    assert columns[0]["nullable"] is None


def test_describing_a_relation_asks_for_columns_and_nullability():
    backend = FakeBackend(
        replies=[
            describe_rows(),
            [
                {"column_name": "amount", "is_nullable": "YES"},
                {"column_name": "order_id", "is_nullable": "NO"},
            ],
        ]
    )
    columns = describe_relation(
        backend, TableId(catalog="main", schema="sales", table="orders")
    )
    assert backend.queries[0] == "DESCRIBE TABLE `main`.`sales`.`orders`"
    assert "system.information_schema.columns" in backend.queries[1]
    assert columns[0]["nullable"] is True


def test_the_legacy_metastore_is_not_asked_for_nullability():
    backend = FakeBackend(replies=[describe_rows()])
    describe_relation(
        backend, TableId(catalog="hive_metastore", schema="default", table="legacy")
    )
    assert len(backend.queries) == 1


# --- namespaces ------------------------------------------------------------


def test_the_current_namespace_comes_from_the_connection():
    backend = FakeBackend(replies=[[{"catalog": "main", "schema": "sales"}]])
    assert current_namespace(backend) == Selector(catalog="main", schema="sales")


def test_a_connection_with_no_current_namespace_is_refused():
    backend = FakeBackend(replies=[[{"catalog": "main", "schema": None}]])
    with pytest.raises(ValueError, match="no current catalog and schema"):
        current_namespace(backend)


def test_a_selection_without_a_catalog_borrows_the_current_one():
    backend = FakeBackend(
        replies=[[{"catalog": "main", "schema": "ignored"}], unity_rows()]
    )
    list_relations(backend, Selector(schema="sales"))
    assert "table_catalog = 'main'" in backend.queries[1]
    assert "table_schema = 'sales'" in backend.queries[1]


# --- exact lookup ----------------------------------------------------------


def test_an_exact_relation_is_matched_by_name():
    backend = FakeBackend(replies=[unity_rows()])
    found = exact_relation(
        backend, Selector(catalog="main", schema="sales", table="orders")
    )
    assert found is not None
    assert found.id.label == "main.sales.orders"
    assert found.identity is not None


def test_an_exact_relation_the_warehouse_does_not_have_is_not_found():
    backend = FakeBackend(replies=[[]])
    found = exact_relation(
        backend, Selector(catalog="main", schema="sales", table="absent")
    )
    assert found is None

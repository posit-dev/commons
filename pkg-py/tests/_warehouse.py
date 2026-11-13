"""A warehouse backend that answers from canned rows.

It stands in for the network, not for a warehouse's semantics: the row shapes
come from `tests/shared/catalog-rows.json`, which is the file that governs how
both packages read a listing, and refusing a relation is how a real warehouse
refuses one, so what is exercised is commons' handling of both.

`FakeWarehouse` speaks Snowflake and `FakeDatabricks` speaks Databricks. They
answer different queries because the two readers ask different ones, and a
fake that answered both would hide a reader wired to the wrong warehouse.
"""

import re

from commons._catalog import MergedDictionary, Relation, merge_dictionary
from commons._data_dictionary import DataDictionary
from commons._data_source import TableId
from tests._shared import load_shared_fixture

__all__ = [
    "FakeDatabricks",
    "FakeWarehouse",
    "column_row",
    "databricks_column_row",
    "databricks_relation_row",
    "merge_shared_case",
    "relation_row",
    "semantic_view_row",
]


def _shape(backend: str, group: str, accept) -> dict:
    """A row of the shared fixture the readers accept, as a template to vary.

    Taking the shape from the fixture rather than restating it means a change
    to what a warehouse returns reaches these fakes instead of leaving them
    answering with a shape the readers no longer expect.
    """
    rows = load_shared_fixture("catalog-rows")[backend][group]["rows"]
    for row in rows:
        if accept(row):
            return dict(row)
    raise AssertionError(f"no usable {backend} {group} row")


def relation_row(name: str, catalog: str = "ANALYTICS", schema: str = "PUBLIC") -> dict:
    row = _shape("snowflake", "relations", lambda row: row["kind"] == "TABLE")
    row.update(name=name, database_name=catalog, schema_name=schema, comment="")
    return row


def semantic_view_row(
    name: str, catalog: str = "ANALYTICS", schema: str = "PUBLIC"
) -> dict:
    """A `SHOW SEMANTIC VIEWS` row, shaped like the shared fixture's."""
    case = load_shared_fixture("snowflake-semantic-views")["show_rows"]["cases"][0]
    row = dict(case["rows"][0])
    row.update(name=name, database_name=catalog, schema_name=schema)
    return row


def column_row(name: str) -> dict:
    row = _shape("snowflake", "columns", lambda row: row["kind"] == "COLUMN")
    row.update(name=name, type="NUMBER(38,0)", comment="")
    row["null?"] = "N"
    return row


def databricks_relation_row(name: str, catalog: str = "main", schema: str = "sales"):
    row = _shape("databricks", "relations", lambda row: row["table_type"] != "VIEW")
    row.update(
        table_catalog=catalog, table_schema=schema, table_name=name, comment=""
    )
    return row


def databricks_column_row(name: str) -> dict:
    # A DESCRIBE reply runs on past the columns, so the template is a row
    # from before the metadata marker.
    row = _shape(
        "databricks",
        "columns",
        lambda row: row["col_name"] not in ("", "# Partition Information"),
    )
    row.update(col_name=name, data_type="bigint", comment="")
    return row


class _Recorder:
    def __init__(self):
        self.queries: list[str] = []
        self.params: list[dict | None] = []
        self.refuse: set[str] = set()

    def _probe(self, sql: str):
        for name in self.refuse:
            if name in sql:
                raise PermissionError(f"Insufficient privileges on {name}")
        return []

    def quote(self, table_id: TableId) -> str:
        return ".".join(f'"{part}"' for part in table_id.parts)

    def columns(self, table_id: TableId) -> list[dict]:
        # A warehouse's columns come from its own reader, which asks with a
        # DESCRIBE rather than through this.
        raise AssertionError("a warehouse describes its own relations")

    def inspector(self):
        return None


class FakeWarehouse(_Recorder):
    """A Snowflake standing in for the network, answering from canned rows."""

    def __init__(
        self,
        dialect="snowflake",
        relations=None,
        role="REPORTER",
        columns=("ID",),
        semantic_views=None,
        semantic_listing_fails=False,
    ):
        super().__init__()
        self._dialect = dialect
        self._relations = relations if relations is not None else ["SALES", "ORDERS"]
        self._columns = list(columns)
        self.role = role
        # View name to the YAML specification Snowflake returns for it, all in
        # ANALYTICS.PUBLIC.
        self.semantic_views = dict(semantic_views or {})
        self.semantic_listing_fails = semantic_listing_fails
        self.yaml_reads: list[str] = []
        # What a SEMANTIC_VIEW query that is not a zero-row probe returns.
        self.semantic_rows: list[dict] = [{"revenue": 1200.0}]

    def query(self, sql: str, params=None):
        self.queries.append(sql)
        self.params.append(params)
        if sql.startswith("SELECT CURRENT_USER()"):
            return [
                {
                    "PRINCIPAL": "ANALYST",
                    "ROLE": self.role,
                    "SECONDARY_ROLES": "ALL",
                    "CATALOG": "ANALYTICS",
                    "SCHEMA": "PUBLIC",
                }
            ]
        if sql.startswith("SELECT CURRENT_DATABASE()"):
            return [{"CATALOG": "ANALYTICS", "SCHEMA": "PUBLIC"}]
        if sql.startswith("SHOW OBJECTS"):
            return [
                relation_row(name)
                for name in self._relations
                if f"'{name}'" in sql or "LIKE" not in sql
            ]
        if sql.startswith("DESC TABLE"):
            return [column_row(name) for name in self._columns]
        if sql.startswith("SHOW SEMANTIC VIEWS"):
            if self.semantic_listing_fails:
                raise PermissionError("SHOW SEMANTIC VIEWS is not authorized")
            return [
                semantic_view_row(name)
                for name in self.semantic_views
                if f"'{name}'" in sql or "LIKE" not in sql
            ]
        if sql.startswith("SELECT SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW"):
            name = re.findall(r'"([^"]*)"', sql)[-1]
            self.yaml_reads.append(name)
            return [{"SPECIFICATION": self.semantic_views[name]}]
        if sql.startswith("SELECT * FROM SEMANTIC_VIEW(") and "LIMIT 0" not in sql:
            self._probe(sql)
            return [dict(row) for row in self.semantic_rows]
        if sql.startswith("SELECT * FROM"):
            return self._probe(sql)
        raise AssertionError(f"unexpected query: {sql}")

    def list_tables(self) -> list[str]:
        return list(self._relations)

    def dialect(self) -> str:
        return self._dialect


class FakeDatabricks(_Recorder):
    """A Databricks standing in for the network.

    Unity Catalog only: `hive_metastore` takes a different listing path and
    nothing here selects it.
    """

    def __init__(self, relations=None, columns=("id",)):
        super().__init__()
        self._relations = relations if relations is not None else ["sales", "orders"]
        self._columns = list(columns)

    def query(self, sql: str, params=None):
        self.queries.append(sql)
        self.params.append(params)
        if sql.startswith("SELECT CURRENT_USER()"):
            return [
                {"principal": "analyst@example.com", "catalog": "main", "schema": "sales"}
            ]
        if sql.startswith("SELECT CURRENT_CATALOG()"):
            return [{"catalog": "main", "schema": "sales"}]
        if "system.information_schema.columns" in sql:
            # DESCRIBE TABLE does not report nullability, so the reader asks
            # the information schema for it separately.
            return [
                {"column_name": name, "is_nullable": "YES"} for name in self._columns
            ]
        if "system.information_schema.tables" in sql:
            return [
                databricks_relation_row(name)
                for name in self._relations
                if f"'{name}'" in sql or "table_name =" not in sql
            ]
        if sql.startswith("DESCRIBE TABLE"):
            return [databricks_column_row(name) for name in self._columns]
        if sql.startswith("SELECT * FROM"):
            return self._probe(sql)
        raise AssertionError(f"unexpected query: {sql}")

    def list_tables(self) -> list[str]:
        return list(self._relations)

    def dialect(self) -> str:
        return "databricks"


def merge_shared_case(case: dict) -> MergedDictionary:
    """Merge a shared fixture case's dictionary into its listed relations."""
    relations = {}
    for entry in case["relations"]:
        relations[entry["label"]] = Relation(
            id=TableId(
                catalog=entry.get("catalog"),
                schema=entry.get("schema"),
                table=entry["table"],
            ),
            kind=entry.get("kind"),
            description=entry.get("description"),
        )
    columns = {entry["label"]: entry["columns"] for entry in case["relations"]}
    dictionary = DataDictionary.model_validate(case["dictionary"])
    return merge_dictionary(
        dictionary,
        relations,
        describe_relation=lambda table_id: columns[table_id.label],
        identifier_case=case["identifier_case"],
    )

"""A warehouse backend that answers from canned rows.

It stands in for the network, not for a warehouse's semantics: the row shapes
are the ones Snowflake really returns, and refusing a relation is how a real
warehouse refuses one, so what is exercised is commons' handling of both.
"""

from commons._data_source import TableId

__all__ = ["FakeWarehouse"]


class FakeWarehouse:
    """A Snowflake standing in for the network, answering from canned rows."""

    def __init__(
        self, dialect="snowflake", relations=None, role="REPORTER", columns=("ID",)
    ):
        self._dialect = dialect
        self._relations = relations if relations is not None else ["SALES", "ORDERS"]
        self._columns = list(columns)
        self.role = role
        self.queries: list[str] = []
        self.refuse: set[str] = set()

    def query(self, sql: str):
        self.queries.append(sql)
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
                {
                    "name": name,
                    "database_name": "ANALYTICS",
                    "schema_name": "PUBLIC",
                    "kind": "TABLE",
                    "comment": "",
                }
                for name in self._relations
                if f"'{name}'" in sql or "LIKE" not in sql
            ]
        if sql.startswith("DESC TABLE"):
            return [
                {
                    "name": name,
                    "type": "NUMBER(38,0)",
                    "kind": "COLUMN",
                    "null?": "N",
                    "comment": "",
                }
                for name in self._columns
            ]
        if sql.startswith("SELECT * FROM"):
            for name in self.refuse:
                if name in sql:
                    raise PermissionError(f"Insufficient privileges on {name}")
            return []
        raise AssertionError(f"unexpected query: {sql}")

    def list_tables(self) -> list[str]:
        return list(self._relations)

    def quote(self, table_id: TableId) -> str:
        return ".".join(f'"{part}"' for part in table_id.parts)

    def dialect(self) -> str:
        return self._dialect

    def inspector(self):
        return None

"""A bounded DuckDB execution registry shared by REST and MCP."""

from __future__ import annotations

import hashlib
import json
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import duckdb
import sqlglot
from sqlglot import expressions as exp
from sqlglot.optimizer.scope import traverse_scope
from sqlglot.tokens import TokenType

from commons._data_source import _fold
from commons._mcp import _validator
from commons._mcp_contract import ENVELOPE_SCHEMA
from commons._mcp_contract import EXECUTION_TAGS as _TAGS
from commons._measures import SemanticLayer, measure_schema_text, resolve_injections
from commons._sql_guard import check_query

_FUNCTIONS = {
    "SUM",
    "COUNT",
    "AVG",
    "MIN",
    "MAX",
    "COALESCE",
    "ROUND",
    "ABS",
    "LOWER",
    "UPPER",
    "DATE_TRUNC",
    "CAST",
    "EXTRACT",
}


def authorize_sql(sql: str, tables: set[str]) -> None:
    """Authorize resolved physical relations and a small built-in function set."""
    _check_sql_budget(sql)
    check_query(sql, "duckdb")
    tree = sqlglot.parse_one(sql, read="duckdb")
    for scope in traverse_scope(tree):
        for _, relation in scope.selected_sources.values():
            if isinstance(relation, exp.Table):
                _authorize_relation(relation, tables)
    for function in tree.find_all(exp.Func):
        name = (
            function.name
            if isinstance(function, exp.Anonymous)
            else function.sql_name()
        )
        if name.upper() not in _FUNCTIONS:
            raise ValueError(f"SQL function {name!r} is not approved.")


def _authorize_relation(relation: exp.Table, tables: set[str]) -> None:
    if not isinstance(relation.this, exp.Identifier):
        raise TypeError("Table functions and external data are forbidden.")
    if relation.catalog or relation.db not in {"", "main"}:
        raise ValueError("Only the configured source namespace is allowed.")
    if _fold(relation.name) not in tables:
        raise ValueError("The query references an unauthorized relation.")


def _check_sql_budget(sql: str) -> None:
    if len(sql.encode()) > 65_536:
        raise ValueError("SQL exceeds the 64 KiB input limit.")
    tokens = sqlglot.tokenize(sql, read="duckdb")
    if len(tokens) > 2048:
        raise ValueError("SQL exceeds the 2048 token limit.")
    depth = 0
    for token in tokens:
        if token.token_type in {
            TokenType.L_PAREN,
            TokenType.L_BRACKET,
            TokenType.L_BRACE,
        }:
            depth += 1
        elif token.token_type in {
            TokenType.R_PAREN,
            TokenType.R_BRACKET,
            TokenType.R_BRACE,
        }:
            depth -= 1
        if depth > 32:
            raise ValueError("SQL exceeds the nesting limit.")


@dataclass(frozen=True)
class Source:
    tables: tuple[str, ...]
    dictionary: str


@dataclass(frozen=True)
class Context:
    text: str
    sources: frozenset[str]


@dataclass(frozen=True)
class Resource:
    uri: str
    title: str
    kind: str
    text: str
    sources: frozenset[str]


class _OutputLimit(ValueError):
    pass


def _check_value_budget(value: Any, budget: int) -> None:
    pending = [iter((value,))]
    while pending:
        try:
            item = next(pending[-1])
        except StopIteration:
            pending.pop()
            continue
        budget -= 1
        if budget < 0:
            raise _OutputLimit("Calculation output exceeded the byte limit.")
        if isinstance(item, (str, bytes)):
            budget -= len(item)
        elif isinstance(item, dict):
            pending.append(iter(item.items()))
        elif isinstance(item, (list, tuple)):
            pending.append(iter(item))
    if budget < 0:
        raise _OutputLimit("Calculation output exceeded the byte limit.")


def _bounded_json(value: Any, budget: int) -> str:
    _check_value_budget(value, budget)
    chunks = []
    size = 0
    for chunk in json.JSONEncoder(default=str, allow_nan=False).iterencode(value):
        size += len(chunk.encode())
        if size > budget:
            raise _OutputLimit("Calculation output exceeded the byte limit.")
        chunks.append(chunk)
    return "".join(chunks)


class Registry:
    """Named datasets in one DuckDB database and an immutable semantic snapshot.

    shortcut: DuckDB and shared datasets only; add backend/principal factories
    before supporting warehouse credentials or tenant-specific data.
    """

    def __init__(
        self,
        database: Path,
        layer: SemanticLayer,
        dictionary: str,
        contexts: dict[str, str | Context],
        *,
        tables: tuple[str, ...] = ("orders",),
        extra_sources: dict[str, Source] | None = None,
    ) -> None:
        self.database = database
        self.layer = layer
        self.sources = {"warehouse": Source(tables, dictionary)}
        if extra_sources and "warehouse" in extra_sources:
            raise ValueError("Additional sources cannot replace warehouse.")
        self.sources.update(extra_sources or {})
        self.source_tables = {
            name: {_fold(table) for table in source.tables}
            for name, source in self.sources.items()
        }
        self.tables = set().union(*self.source_tables.values())
        self.row_limit = 100
        self.byte_limit = 64_000
        self.deadline = 2.0
        with duckdb.connect(str(database), read_only=True) as connection:
            self._check_tables(connection)
        self.resources = self._resources(contexts)
        self.operations = self._operations()
        snapshot = json.dumps(
            {
                "tools": self.operations,
                "sources": {
                    name: sorted(tables) for name, tables in self.source_tables.items()
                },
                "resources": [
                    vars(r) | {"sources": sorted(r.sources)}
                    for r in self.resources.values()
                ],
            },
            sort_keys=True,
        )
        self.revision = hashlib.sha256(snapshot.encode()).hexdigest()[:16]

    def _resources(self, contexts: dict[str, str | Context]) -> dict[str, Resource]:
        return {
            **{
                f"commons://sources/{name}/data-dict.yaml": Resource(
                    f"commons://sources/{name}/data-dict.yaml",
                    f"{name} dictionary",
                    "schema",
                    source.dictionary,
                    frozenset({name}),
                )
                for name, source in self.sources.items()
            },
            **{
                f"commons://contexts/{key}": self._context_resource(key, text)
                for key, text in contexts.items()
            },
            **{
                f"commons://measures/{name}": Resource(
                    f"commons://measures/{name}",
                    record.title,
                    "definition",
                    measure_schema_text(record, source_names=list(self.sources)),
                    frozenset(record.injected) & self.sources.keys(),
                )
                for name, record in self.layer.measures.items()
            },
        }

    def _context_resource(self, key: str, value: str | Context) -> Resource:
        context = (
            value
            if isinstance(value, Context)
            else Context(value, frozenset({"warehouse"}))
        )
        if not context.sources <= self.sources.keys():
            raise ValueError("A context names unknown sources.")
        return Resource(
            f"commons://contexts/{key}", key, "prose", context.text, context.sources
        )

    def _operations(self) -> dict[str, dict[str, Any]]:
        operations = {
            name: {
                "name": name,
                "description": record.description,
                "inputSchema": record.params.model_json_schema(),
                "execution_kind": "trusted_calculation",
                "outputSchema": ENVELOPE_SCHEMA,
                "resource_uri": f"commons://measures/{name}",
            }
            for name, record in self.layer.measures.items()
        }
        for name, properties, required, kind, description in (
            (
                "run_sql",
                {
                    "source": self._source_schema(),
                    "sql": {"type": "string", "maxLength": 65_536},
                },
                ["source", "sql"],
                "ad_hoc_sql",
                "Run a bounded read-only DuckDB query on the selected source.",
            ),
            (
                "describe_table",
                {
                    "source": self._source_schema(),
                    "table": {"type": "string", "minLength": 1},
                },
                ["source", "table"],
                "metadata",
                "Inspect a granted source's table schema and up to five raw rows. This tool grants sample-row access.",
            ),
        ):
            if name in operations:
                raise ValueError("Measure names cannot replace service operations.")
            operations[name] = {
                "name": name,
                "description": description,
                "inputSchema": {
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": False,
                },
                "execution_kind": kind,
                "outputSchema": ENVELOPE_SCHEMA,
            }
        return operations

    def _source_schema(self) -> dict[str, Any]:
        return {"type": "string", "minLength": 1}

    def visible_resources(
        self, allowed: frozenset[str], sources: frozenset[str]
    ) -> dict[str, Resource]:
        return {
            uri: resource
            for uri, resource in self.resources.items()
            if resource.sources <= sources
            and (
                resource.kind != "definition"
                or uri.removeprefix("commons://measures/") in allowed
            )
        }

    def catalog(
        self, allowed: frozenset[str], sources: frozenset[str] | None = None
    ) -> dict[str, Any]:
        """Filter execution grants within the global immutable metadata revision."""
        sources = frozenset(self.sources) if sources is None else sources
        return {
            "contract_version": "1",
            "catalog_revision": self.revision,
            "tools": [
                record
                for name, record in self.operations.items()
                if name in allowed and self._execution_sources(name, {}) <= sources
            ],
            "resources": [
                {
                    "uri": r.uri,
                    "title": r.title,
                    "kind": r.kind,
                    "revision": self.revision,
                }
                for r in self.visible_resources(allowed, sources).values()
            ],
            "sources": [
                {
                    "id": name,
                    "dialect": "duckdb",
                    "tables": sorted(tables),
                    "sql_enabled": "run_sql" in allowed,
                }
                for name, tables in self.source_tables.items()
                if name in sources
            ],
        }

    def execute(
        self,
        name: str,
        arguments: dict[str, Any],
        allowed: frozenset[str],
        revision: str,
        *,
        sources: frozenset[str] | None = None,
    ) -> dict[str, Any]:
        started = time.monotonic()
        if name not in allowed or name not in self.operations:
            raise PermissionError("This principal cannot execute the requested tool.")
        if revision != self.revision:
            raise ValueError(
                "Catalog revision mismatch; rebuild the agent between turns."
            )
        _validator(self.operations[name]["inputSchema"]).validate(arguments)
        sources = frozenset(self.sources) if sources is None else sources
        if not self._execution_sources(name, arguments) <= sources:
            raise PermissionError("This principal cannot access the requested source.")
        if name == "run_sql":
            authorize_sql(arguments["sql"], self.source_tables[arguments["source"]])
        if name == "describe_table" and _fold(
            arguments["table"]
        ) not in self.source_tables.get(arguments["source"], set()):
            raise ValueError("The table does not belong to the requested source.")
        remaining = self.deadline - (time.monotonic() - started)
        if remaining <= 0:
            raise ValueError("The request exceeded its validation deadline.")
        data, truncated = self._execute_database(name, arguments, remaining)
        data = json.loads(_bounded_json(data, self.byte_limit))
        return self._envelope(name, arguments, data, truncated)

    def _execution_sources(
        self, name: str, arguments: dict[str, Any]
    ) -> frozenset[str]:
        if name in self.layer.measures:
            return frozenset(self.layer.measures[name].injected) & self.sources.keys()
        return (
            frozenset({arguments["source"]}) if "source" in arguments else frozenset()
        )

    def _envelope(
        self, name: str, arguments: dict[str, Any], data: Any, truncated: bool
    ) -> dict[str, Any]:
        sources = sorted(self._execution_sources(name, arguments))
        envelope = {
            "data": data,
            "commons": {
                "contract_version": "1",
                "catalog_revision": self.revision,
                "tool_id": name,
                "execution_kind": self.operations[name]["execution_kind"],
                "provenance_tag": _TAGS[self.operations[name]["execution_kind"]],
                "sources": sources,
                "applied_definitions": [],
                "evidence": [
                    {
                        "uri": f"commons://sources/{source}/data-dict.yaml",
                        "revision": self.revision,
                    }
                    for source in sources
                ],
                "coverage": {"truncated": truncated},
            },
        }
        if name in self.layer.measures:
            envelope["commons"]["evidence"].append(
                {
                    "uri": f"commons://measures/{name}",
                    "revision": self.revision,
                }
            )
        _validator(ENVELOPE_SCHEMA).validate(envelope)
        return envelope

    def _execute_database(
        self,
        name: str,
        arguments: dict[str, Any],
        remaining: float,
    ) -> tuple[Any, bool]:
        with duckdb.connect(
            str(self.database),
            read_only=True,
            config={
                "enable_external_access": False,
                "threads": 1,
                "memory_limit": "128MB",
            },
        ) as connection:
            deadline = threading.Timer(remaining, connection.interrupt)
            deadline.start()
            try:
                self._check_tables(connection)
                return self._dispatch(connection, name, arguments)
            except duckdb.Error:
                raise ValueError(
                    "Database execution failed or exceeded its resource deadline."
                ) from None
            finally:
                deadline.cancel()
                deadline.join()

    def _check_tables(self, connection: Any) -> None:
        available = connection.execute(
            "SELECT table_name FROM duckdb_tables() "
            "WHERE database_name=current_database() AND schema_name='main' AND NOT temporary"
        ).fetchall()
        if not self.tables <= {_fold(row[0]) for row in available}:
            raise ValueError(
                "Configured relations must be existing base tables; views are unsupported."
            )

    def _dispatch(
        self, connection: Any, name: str, arguments: dict[str, Any]
    ) -> tuple[Any, bool]:
        if name == "run_sql":
            cursor = connection.execute(arguments["sql"])
            return self._rows(cursor)
        if name == "describe_table":
            table = arguments["table"].replace('"', '""')
            columns, schema_truncated = self._rows(
                connection.execute(f'DESCRIBE "{table}"')
            )
            sample, sample_truncated = self._rows(
                connection.execute(f'SELECT * FROM "{table}" LIMIT 5')
            )
            return {
                "schema": columns["rows"],
                "sample": sample,
            }, schema_truncated or sample_truncated
        measure = self.layer.measures[name]
        injections = resolve_injections(
            {name: measure}, dict.fromkeys(self.sources, connection)
        )
        value = measure.func(**measure.validate_args(arguments), **injections[name])
        return value, False

    def _rows(self, cursor: Any) -> tuple[dict[str, Any], bool]:
        columns = [column[0] for column in cursor.description]
        rows = []
        result = {"columns": columns, "rows": rows}
        size = len(_bounded_json(result, self.byte_limit).encode())
        for _ in range(self.row_limit):
            row = cursor.fetchone()
            if row is None:
                return result, False
            # shortcut: the driver materializes one cell; use streaming for large BLOB deployments.
            try:
                encoded = _bounded_json(row, self.byte_limit - size - 2)
            except _OutputLimit:
                return result, True
            rows.append(json.loads(encoded))
            size += len(encoded.encode()) + 2
        return result, cursor.fetchone() is not None

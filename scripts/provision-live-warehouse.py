#!/usr/bin/env python3
"""Emit the SQL that brings a warehouse to the state the live tests expect.

The tables, columns and rows come from ``tests/shared/live-warehouse-rows.json``
so that the warehouse and the DuckDB the suites compare against hold the same
data. The schema, the denied table, the semantic models and the Snowflake
alternate role are named in ``tests/shared/live-warehouse-env.json``, which the
tests read too. Nothing is generated into the repository: the SQL is printed for
a person to run, which leaves no committed artifact to go stale.

    python3 scripts/provision-live-warehouse.py databricks <application-id>
    python3 scripts/provision-live-warehouse.py snowflake <role>

The second argument names the principal the tests connect as: a Databricks
service principal's application ID, or a Snowflake role. Its grants cover the
fixture tables and models and leave out a copy of one table, which becomes the
denied table. That works because the principal that runs this SQL owns the
copy, and on Snowflake that is the active role. Run it under a role other than
the test principal, or the test principal owns the copy and can read it.

On Snowflake it also creates the semantic views and grants the test role the
alternate role. On Databricks it creates the parameterized metric view.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

SHARED = Path(__file__).resolve().parent.parent / "tests" / "shared"
FIXTURE = SHARED / "live-warehouse-rows.json"
ENV = SHARED / "live-warehouse-env.json"

# Snowflake semantic views over the orders table. Each is YAML for
# SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML, with {database} and {schema} filled in
# as YAML scalars and {namespace} as the quoted identifiers the verified query's
# SQL names. The view names are the ones live-warehouse-env.json gives. Snowflake
# stores a semantic view's member names in upper case, so the YAML spells them
# that way too.
SEMANTIC_VIEWS = {
    "ORDERS_MODEL": """\
name: ORDERS_MODEL
description: Orders from the commons live-test fixture.
tables:
  - name: orders
    base_table:
      database: '{database}'
      schema: '{schema}'
      table: '"orders"'
    dimensions:
      - name: tile_size
        expr: '"tile_size"'
        data_type: VARCHAR
    facts:
      - name: order_total
        expr: '"order_total"'
        data_type: FLOAT
    metrics:
      - name: total_order_value
        description: Sum of order totals.
        expr: SUM(orders.order_total)
verified_queries:
  - name: total_order_value_by_tile
    question: What is the total order value for each tile size?
    sql: SELECT "tile_size", SUM("order_total") AS total_order_value FROM {namespace}."orders" GROUP BY "tile_size"
""",
    "ORDERS_PARAM_MODEL": """\
name: ORDERS_PARAM_MODEL
description: Orders from the commons live-test fixture, with a threshold variable.
variables:
  - name: MIN_TOTAL
    data_type: NUMBER(10,2)
    default_value: "0"
    description: Only orders whose total is at least this amount count.
tables:
  - name: orders
    base_table:
      database: '{database}'
      schema: '{schema}'
      table: '"orders"'
    facts:
      - name: order_total
        expr: '"order_total"'
        data_type: FLOAT
    metrics:
      - name: total_above_min
        description: Sum of order totals at or above MIN_TOTAL.
        expr: SUM(CASE WHEN orders.order_total >= MIN_TOTAL THEN orders.order_total ELSE 0 END)
""",
}

# The Databricks metric view, with {source} filled in as the orders table's
# dotted name, left unquoted because YAML reserves a leading backtick. The arguments the tests bind (live-warehouse-env.json) differ
# from the default, so a bound value changes the answer.
METRIC_VIEW = """\
version: 1.1
comment: Orders from the commons live-test fixture, with a threshold parameter.
source: {source}
parameters:
  - name: min_total
    data_type: double
    default: 0
    comment: Only orders whose total is at least this amount count.
dimensions:
  - name: tile_size
    expr: tile_size
measures:
  - name: total_above_min
    comment: Sum of order totals at or above min_total.
    expr: SUM(CASE WHEN order_total >= min_total THEN order_total ELSE 0 END)
"""

SPECIAL_DOUBLES = {
    "databricks": {"NaN": "double('NaN')", "Infinity": "double('Infinity')", "-Infinity": "double('-Infinity')"},
    "snowflake": {"NaN": "'NaN'::FLOAT", "Infinity": "'Inf'::FLOAT", "-Infinity": "'-Inf'::FLOAT"},
}


def quote_string(value: str) -> str:
    """A string literal for either warehouse.

    Both treat a backslash inside a literal as an escape, so both need the
    same doubling, and a tab is written as an escape rather than embedded so
    the generated SQL survives being pasted into a query editor.
    """
    escaped = value.replace("\\", "\\\\").replace("'", "''").replace("\t", "\\t").replace("\n", "\\n")
    return f"'{escaped}'"


def literal(value: Any, type_name: str, types: dict[str, Any], dialect: str) -> str:
    if value is None:
        return f"CAST(NULL AS {types[type_name][dialect]})"
    if type_name == "boolean":
        return "TRUE" if value else "FALSE"
    if type_name == "int64":
        return str(value)
    if type_name == "double":
        if isinstance(value, str):
            return SPECIAL_DOUBLES[dialect][value]
        return repr(float(value))
    if type_name == "string":
        return quote_string(value)
    if type_name == "date":
        return f"DATE {quote_string(value)}"
    if type_name == "timestamp":
        stamp = value.replace("T", " ").replace("Z", "+00:00")
        if dialect == "databricks":
            return f"TIMESTAMP {quote_string(stamp)}"
        return f"{quote_string(stamp)}::TIMESTAMP_TZ"
    if type_name == "string_array":
        items = ", ".join(quote_string(item) for item in value)
        if dialect == "databricks":
            return f"CAST(array({items}) AS ARRAY<STRING>)"
        return f"ARRAY_CONSTRUCT({items})"
    if type_name == "profile_struct":
        return struct_literal(value, types[type_name][dialect], dialect)
    raise ValueError(f"No literal rule for type {type_name!r}")


def struct_literal(value: dict[str, Any], declared: str, dialect: str) -> str:
    """The profile column, whose shape is fixed by the corpus dictionary.

    Written against that one shape rather than driven by the declared type,
    because a general struct renderer would have to parse two dialects' type
    grammars to learn the field types, and there is only one struct here.
    """
    latitude = value["geo"]["latitude"] if value.get("geo") else None
    if dialect == "databricks":
        geo = "CAST(NULL AS DOUBLE)" if latitude is None else repr(float(latitude))
        inner = f"named_struct('latitude', {geo})"
        fields = (
            f"'zip', {quote_string(value['zip'])}, "
            f"'geo', {inner}, "
            f"'nick names', {quote_string(value['nick names'])}"
        )
        return f"CAST(named_struct({fields}) AS {declared})"
    geo = "NULL" if latitude is None else repr(float(latitude))
    inner = f"OBJECT_CONSTRUCT_KEEP_NULL('latitude', {geo})"
    fields = (
        f"'zip', {quote_string(value['zip'])}, "
        f"'geo', {inner}, "
        f"'nick names', {quote_string(value['nick names'])}"
    )
    return f"CAST(OBJECT_CONSTRUCT_KEEP_NULL({fields}) AS {declared})"


def quote_identifier(name: str, dialect: str) -> str:
    if dialect == "databricks":
        return "`" + name.replace("`", "``") + "`"
    return '"' + name.replace('"', '""') + '"'


def provisioned(dialect: str) -> dict[str, Any]:
    """The names live-warehouse-env.json fixes for one backend."""
    return json.loads(ENV.read_text(encoding="utf-8"))["backends"][dialect]["provisioned"]


def render(dialect: str, grantee: str) -> str:
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    names = provisioned(dialect)
    types = fixture["types"]
    parts = names["namespace"]
    qualified = ".".join(quote_identifier(part, dialect) for part in parts)

    lines = [
        f"-- Generated by scripts/provision-live-warehouse.py for {dialect}.",
        "-- Rows come from tests/shared/live-warehouse-rows.json; edit that file, not this output.",
        "",
        f"CREATE SCHEMA IF NOT EXISTS {qualified};",
        "",
    ]

    for table, spec in fixture["tables"].items():
        target = f"{qualified}.{quote_identifier(table, dialect)}"
        columns = ",\n".join(
            f"  {quote_identifier(column['name'], dialect)} {types[column['type']][dialect]}"
            for column in spec["columns"]
        )
        # Delta rejects a space in a column or struct field name, such as
        # survey's `nick names`, unless the table maps columns by name.
        close = ");"
        if dialect == "databricks":
            close = ")\nTBLPROPERTIES ('delta.columnMapping.mode' = 'name');"
        lines += [
            f"DROP TABLE IF EXISTS {target};",
            f"CREATE TABLE {target} (",
            columns,
            close,
            "",
        ]
        column_list = ", ".join(quote_identifier(c["name"], dialect) for c in spec["columns"])
        rows = [
            ", ".join(
                literal(row[column["name"]], column["type"], types, dialect)
                for column in spec["columns"]
            )
            for row in spec["rows"]
        ]
        if dialect == "snowflake":
            # Snowflake accepts only constants in a VALUES list, and the
            # array and object literals are function calls.
            values = "\nUNION ALL ".join(f"SELECT {row}" for row in rows)
            lines += [f"INSERT INTO {target} ({column_list})", values + ";", ""]
        else:
            values = ",\n".join(f"  ({row})" for row in rows)
            lines += [f"INSERT INTO {target} ({column_list}) VALUES", values + ";", ""]

    if dialect == "snowflake":
        lines += semantic_views(parts)
    else:
        lines += metric_view(parts, names["parameterized_model"])
    lines += grants(dialect, names, qualified, list(fixture["tables"]), grantee)
    return "\n".join(lines) + "\n"


def grants(
    dialect: str, names: dict[str, Any], qualified: str, tables: list[str], grantee: str
) -> list[str]:
    """Read access for the test principal, and a table it is refused."""
    principal = quote_identifier(grantee, dialect)
    denied = f"{qualified}.{quote_identifier(names['denied_table'], dialect)}"
    lines = [
        f"-- Run this as a principal other than {principal}. An owner can read its own",
        f"-- tables, so {principal} must not own {denied}.",
        f"DROP TABLE IF EXISTS {denied};",
        f"CREATE TABLE {denied} AS SELECT * FROM {qualified}.{quote_identifier('orders', dialect)};",
        "",
    ]
    if dialect == "databricks":
        catalog = quote_identifier(names["namespace"][0], dialect)
        lines += [
            f"-- {principal} also needs USE CATALOG on {catalog}, from its owner.",
            f"GRANT USE SCHEMA ON SCHEMA {qualified} TO {principal};",
        ]
        relations = [*tables, names["parameterized_model"]]
        lines += [
            f"GRANT SELECT ON TABLE {qualified}.{quote_identifier(t, dialect)} TO {principal};"
            for t in relations
        ]
        return lines

    database = quote_identifier(names["namespace"][0], dialect)
    lines += [
        f"GRANT USAGE ON DATABASE {database} TO ROLE {principal};",
        f"GRANT USAGE ON SCHEMA {qualified} TO ROLE {principal};",
    ]
    lines += [f"GRANT SELECT ON TABLE {qualified}.{quote_identifier(t, dialect)} TO ROLE {principal};" for t in tables]
    lines += [
        f"GRANT REFERENCES, SELECT ON SEMANTIC VIEW {qualified}.{quote_identifier(view, dialect)} TO ROLE {principal};"
        for view in SEMANTIC_VIEWS
    ]
    # The active-role test switches to this role and back, so the test role
    # must be able to assume it. Creating a role needs USERADMIN or a role
    # with CREATE ROLE.
    alternate = quote_identifier(names["alternate_role"], dialect)
    lines += [
        "",
        f"CREATE ROLE IF NOT EXISTS {alternate};",
        f"GRANT ROLE {alternate} TO ROLE {principal};",
    ]
    return lines


def semantic_views(parts: list[str]) -> list[str]:
    """The Snowflake semantic views, created from YAML.

    Dollar quoting keeps the YAML's own quotes intact. The procedure takes
    the schema, and the view's name comes from the YAML. A semantic view
    takes a qualified base table, so the catalog and schema are written in.
    """
    database, schema = (quote_identifier(part, "snowflake") for part in parts)
    namespace = f"{database}.{schema}"
    lines = []
    for view, spec in SEMANTIC_VIEWS.items():
        # A YAML single-quoted scalar doubles a quote inside it; the SQL in
        # the verified query takes the identifiers as they are.
        body = spec.format(
            database=database.replace("'", "''"),
            schema=schema.replace("'", "''"),
            namespace=namespace,
        )
        lines += [
            f"DROP SEMANTIC VIEW IF EXISTS {namespace}.{quote_identifier(view, 'snowflake')};",
            f"CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML({quote_string(namespace)}, $$",
            body.rstrip("\n"),
            "$$);",
            "",
        ]
    return lines


def metric_view(parts: list[str], name: str) -> list[str]:
    """The Databricks metric view, created from YAML."""
    qualified = ".".join(quote_identifier(part, "databricks") for part in parts)
    source = ".".join([*parts, "orders"])
    return [
        f"CREATE OR REPLACE VIEW {qualified}.{quote_identifier(name, 'databricks')}",
        "WITH METRICS",
        "LANGUAGE YAML",
        "AS $$",
        METRIC_VIEW.format(source=source).rstrip("\n"),
        "$$;",
        "",
    ]


def main(argv: list[str]) -> int:
    args = argv[1:]
    if len(args) != 2 or args[0] not in ("databricks", "snowflake"):
        print(__doc__, file=sys.stderr)
        print(
            "Usage: provision-live-warehouse.py {databricks|snowflake} <test-principal>",
            file=sys.stderr,
        )
        return 2
    print(render(args[0], args[1]), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

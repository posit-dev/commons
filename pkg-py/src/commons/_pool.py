"""The pool: one discovery surface over an agent's trusted calculations, and
the governed query `call_metrics` compiles.

Measures and governed definitions are ranked together, so the model does not
have to guess which kind holds its answer. `pkg-r/R/pool.R` decides the same
two things for R.
"""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from typing import TYPE_CHECKING, Any

from chatlas import ContentToolResult
from sqlglot import expressions as exp

from ._citations import tool_result
from ._definitions import ExportRecord, applied_text
from ._measures import Measure, measure_schema_text
from ._provenance import Tag
from ._rows import rows_to_markdown
from ._sql_guard import sqlglot_dialect

if TYPE_CHECKING:
    from ._data_source import DataSource
    from ._definitions import Registry
    from ._handles import HandleStore

__all__ = [
    "WHERE_OPERATORS",
    "call_metrics",
    "definition_pool_text",
    "lexical_rank",
    "search_pool_text",
]

WHERE_OPERATORS = ("=", "!=", "<", "<=", ">", ">=")

_NOT_WORD = re.compile(r"[^a-z0-9]+")
_TOKEN_BRACES = re.compile(r"^\{\{\s*|\s*\}\}$")
_NUMERIC = re.compile(r"^-?[0-9]+(\.[0-9]+)?$")


def _tokenize(text: str) -> list[str]:
    # Single characters are dropped: they match too much to rank anything.
    return [term for term in _NOT_WORD.split(text.lower()) if len(term) > 1]


def lexical_rank(query: str, documents: Sequence[str], limit: int = 5) -> list[int]:
    """The positions of the documents sharing the most terms with `query`.

    A term repeated in the query counts each time, and a term repeated in a
    document counts once, so a document is ranked by how much of the query it
    covers rather than by how often it says one word.
    """
    terms = _tokenize(query)
    if not terms or not documents:
        return []
    scored = [
        (sum(term in set(_tokenize(document)) for term in terms), position)
        for position, document in enumerate(documents)
    ]
    hits = [entry for entry in scored if entry[0] > 0]
    # A stable sort on the score alone, so equally scored documents stay in
    # the order the pool presents them.
    hits.sort(key=lambda entry: entry[0], reverse=True)
    return [position for _, position in hits[:limit]]


def _flatten_inline(text: str) -> str:
    return re.sub(r"\s*\n\s*", " ", text).strip()


def _prose_detail(description: str | None, details: str | None) -> str:
    return _flatten_inline(" ".join(part for part in (description, details) if part))


def _strip_token_braces(name: str) -> str:
    # The prompt teaches `{{name}}` for SQL, so models sometimes pass the
    # braces here too; accept both forms.
    return _TOKEN_BRACES.sub("", name.strip())


def search_pool_text(
    measures: Mapping[str, Measure],
    registry: Registry,
    query: str,
    source_names: Sequence[str] = (),
) -> str:
    """The blocks `search_pool` shows for the best matches in the pool."""
    records = registry.records
    entries = list(measures.values())
    if not entries and not records:
        return "The semantic layer is empty."

    catalog = [f"{record.name} {record.description}" for record in entries]
    catalog += [
        " ".join(
            part or ""
            for part in (
                record.name,
                record.table,
                record.kind,
                record.label,
                record.description,
                record.details,
                record.sql,
            )
        )
        for record in records
    ]

    hits = lexical_rank(query, catalog)
    if not hits:
        return (
            f'Nothing in the semantic layer matches "{query}". '
            "Consider writing a SQL query."
        )
    blocks = [
        measure_schema_text(entries[hit], source_names=source_names)
        if hit < len(entries)
        else definition_pool_text(records[hit - len(entries)], records)
        for hit in hits
    ]
    return "\n\n".join(blocks)


def definition_pool_text(record: ExportRecord, records: Sequence[ExportRecord]) -> str:
    """One governed definition as the pool presents it, with how to invoke it.

    Sibling definitions on the same table are named under a metric, because a
    metric is what a grouped or filtered query is built around.
    """
    name = record.name
    table_has_metrics = any(
        other.source == record.source
        and other.table == record.table
        and other.kind == "metric"
        for other in records
    )

    if record.mixed_grain:
        invoke = (
            f"Use `{{{{{name}}}}}` only in run_sql with manually grain-correct "
            "query structure."
        )
    elif record.kind == "filter":
        invoke = f"Apply in run_sql (e.g. `WHERE {{{{{name}}}}}`)"
        invoke += (
            " or as a call_metrics filter or dimension." if table_has_metrics else "."
        )
    elif record.kind == "metric":
        invoke = (
            f'Query with call_metrics (metrics = ["{name}"]) or in run_sql as '
            f"`SELECT {{{{{name}}}}} AS value`."
        )
    else:
        invoke = f"Use in run_sql SELECT or GROUP BY as `{{{{{name}}}}}`"
        invoke += ", or as a call_metrics dimension." if table_has_metrics else "."

    heading = f"### {{{{{name}}}}} --- {record.kind} on table `{record.table}`"
    parts = [
        f"{heading}\n{_prose_detail(record.description, record.details)}",
        f"Selected {record.target}: `({_flatten_inline(record.sql)})`.",
    ]
    if record.notes:
        parts.append(f"Translation notes: {' '.join(record.notes)}")
    parts.append(invoke)

    if record.kind == "metric":
        siblings = [
            other
            for other in records
            # Scoped to this source: a sibling on another source's table of
            # the same name is not reachable from a call_metrics query
            # against this one. pkg-r/R/pool.R lists siblings across sources;
            # the scoping here is deliberate, not shared behavior.
            if other.source == record.source
            and other.table == record.table
            and other.name != record.name
            and other.kind in ("filter", "derived")
            and not other.mixed_grain
        ]
        if siblings:
            listed = ", ".join(
                f"{{{{{other.name}}}}} ({other.kind})" for other in siblings
            )
            parts.append(f"Filters and derived definitions on this table: {listed}.")
    return "\n".join(parts)


# ---- the governed query ---------------------------------------------------


def call_metrics(
    registry: Registry,
    source: DataSource,
    label: str,
    handles: HandleStore | None,
    metrics: list[str],
    dimensions: list[str] | None = None,
    filters: list[str] | None = None,
    where: list[dict[str, Any]] | None = None,
) -> ContentToolResult:
    """Compile and run a governed query over one table's definitions.

    The shape semantic layers converge on: metrics by dimensions with
    filters, plus simple column predicates. Names arrive as strings and are
    validated here, because the provider only ever sees `call_metrics`.
    """
    if not metrics:
        raise ValueError("metrics must name at least one governed metric.")
    defs = registry.for_source(label)
    metric_records = _resolve_names(metrics, defs, "metric")
    _refuse_mixed_grain(
        metric_records,
        "metric",
        "cannot be queried because the dependency chain requires a subquery rewrite",
    )

    tables = list(dict.fromkeys(record.table for record in metric_records))
    if len(tables) > 1:
        raise ValueError(
            f"Metrics in one query must share a table; these span "
            f"{', '.join(tables)}. Query them separately and combine the "
            "results with run_python."
        )
    table = tables[0]
    on_table = [record for record in defs if record.table == table]

    dictionary = source.dictionary
    entry = dictionary.tables.get(table) if dictionary is not None else None
    columns = list(entry.columns) if entry is not None else []
    dialect = sqlglot_dialect(source.backend.dialect())

    dimension_names = [_strip_token_braces(name) for name in dimensions or []]
    dimension_sql = {
        name: _dimension_sql(name, on_table, columns, dialect)
        for name in dimension_names
    }
    filter_records = _resolve_names(filters, on_table, "filter")
    _refuse_mixed_grain(
        filter_records,
        "filter",
        "cannot be applied by call_metrics; use the definition in run_sql",
    )

    conditions = [f"({record.sql})" for record in filter_records]
    conditions += [_where_condition(triple, columns, dialect) for triple in where or []]

    select = [
        f"{sql} AS {_quote_name(name, dialect)}" for name, sql in dimension_sql.items()
    ]
    select += [
        f"({record.sql}) AS {_quote_name(record.name, dialect)}"
        for record in metric_records
    ]
    sql = f"SELECT {', '.join(select)} FROM {source.backend.quote(source.table_ids[table])}"
    if conditions:
        sql += f" WHERE {' AND '.join(conditions)}"
    if dimension_sql:
        sql += f" GROUP BY {', '.join(dimension_sql.values())}"
    else:
        # Force a global group, so a constant stays scalar when no rows remain.
        sql += " HAVING COUNT(*) >= 0"

    rows = source.query(sql)
    advert = handles.register(rows) if handles is not None else None
    applied: list[ExportRecord] = []
    for record in (
        *metric_records,
        *(record for record in on_table if record.name in dimension_names),
        *filter_records,
    ):
        if record not in applied:
            applied.append(record)
    body = "\n\n".join(
        part for part in (rows_to_markdown(rows), applied_text(applied), advert) if part
    )
    return tool_result(body, tag=Tag.A)


def _resolve_names(
    names: list[str] | None, defs: Sequence[ExportRecord], kind: str
) -> list[ExportRecord]:
    return [
        _resolve_name(_strip_token_braces(name), defs, kind) for name in names or []
    ]


def _resolve_name(name: str, defs: Sequence[ExportRecord], kind: str) -> ExportRecord:
    named = _candidates(name, defs)
    matched = [record for record in named if record.kind == kind]
    if len(matched) == 1:
        return matched[0]
    if matched:
        qualified = " or ".join(
            f"{{{{{record.table}::{record.name}}}}}" for record in matched
        )
        raise ValueError(
            f"Governed {kind} name {name!r} is ambiguous. Qualify it as {qualified}."
        )
    if named:
        raise ValueError(
            f"{name!r} is a {named[0].kind}, not a {kind}; apply it as "
            f"{{{{{name}}}}} in SQL instead."
        )
    available = [record.name for record in defs if record.kind == kind]
    raise ValueError(
        f"No governed {kind} is named {name!r}. "
        f"Available {kind}s: {', '.join(available)}."
    )


def _candidates(name: str, defs: Sequence[ExportRecord]) -> list[ExportRecord]:
    if "::" in name:
        table, _, definition = name.partition("::")
        return [
            record
            for record in defs
            if record.table == table and record.name == definition
        ]
    return [record for record in defs if record.name == name]


def _refuse_mixed_grain(
    records: Sequence[ExportRecord], kind: str, reason: str
) -> None:
    mixed = [record.name for record in records if record.mixed_grain]
    if mixed:
        noun = kind if len(mixed) == 1 else f"{kind}s"
        raise ValueError(f"Mixed-grain {noun} {', '.join(mixed)} {reason}.")


def _dimension_sql(
    name: str, defs: Sequence[ExportRecord], columns: list[str], dialect: str | None
) -> str:
    named = _candidates(name, defs)
    if named:
        record = named[0]
        if record.kind not in ("derived", "filter"):
            raise ValueError(f"{name!r} is a {record.kind} and can't be grouped by.")
        if record.mixed_grain:
            raise ValueError(
                f"Mixed-grain definition {name!r} cannot be grouped by with "
                "call_metrics; use it in run_sql."
            )
        return f"({record.sql})"
    if name in columns:
        return _quote_name(name, dialect)
    groupable = [
        record.name
        for record in defs
        if record.kind in ("derived", "filter") and not record.mixed_grain
    ]
    detail = f" Governed row definitions: {', '.join(groupable)}." if groupable else ""
    raise ValueError(
        f"No dimension or documented column is named {name!r}. "
        f"Documented columns: {', '.join(columns)}.{detail}"
    )


def _where_condition(triple: Any, columns: list[str], dialect: str | None) -> str:
    if not isinstance(triple, Mapping):
        raise TypeError("Each where entry needs column, op, and value, as an object.")
    values = {}
    for field in ("column", "op", "value"):
        value = triple.get(field)
        if value is None or not str(value):
            raise ValueError("Each where entry needs column, op, and value.")
        values[field] = str(value)
    if values["column"] not in columns:
        raise ValueError(
            f"where references {values['column']!r}, which is not a documented "
            f"column. Documented columns: {', '.join(columns)}."
        )
    if values["op"] not in WHERE_OPERATORS:
        raise ValueError(
            f"where operator must be one of {', '.join(WHERE_OPERATORS)}, not "
            f"{values['op']!r}."
        )
    # A number is written bare so the comparison stays numeric; anything else
    # is a literal the dialect quotes for itself.
    literal = (
        values["value"]
        if _NUMERIC.match(values["value"])
        else _quote_string(values["value"], dialect)
    )
    return f"({_quote_name(values['column'], dialect)} {values['op']} {literal})"


def _quote_name(name: str, dialect: str | None) -> str:
    return exp.to_identifier(name, quoted=True).sql(dialect=dialect)


def _quote_string(value: str, dialect: str | None) -> str:
    return exp.Literal.string(value).sql(dialect=dialect)

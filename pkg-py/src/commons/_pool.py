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

from ._catalog import _databricks, _snowflake
from ._catalog import _databricks_semantic as databricks_semantic
from ._catalog._snowflake_semantic import metric_sql
from ._citations import tool_result
from ._definitions import ExportRecord, applied_text
from ._display import TRUSTED_CALL, measure_display_html
from ._measures import Measure, measure_schema_text
from ._provenance import Tag
from ._rows import rows_to_markdown
from ._semantic_models import (
    MemberRow,
    SemanticRegistry,
    calculation_pool_text,
    calculations_registry,
    hydrate,
    member_pool_text,
    metric_origin,
    resolve_calculation,
    resolve_filters,
    resolve_members,
    semantic_registry,
    stub_pool_text,
    validate_arguments,
)
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
    semantic: SemanticRegistry | None = None,
) -> str:
    """The blocks `search_pool` shows for the best matches in the pool."""
    records = registry.records
    entries = list(measures.values())
    members = semantic.members if semantic is not None else []
    stubs = semantic.stubs if semantic is not None else []
    calculations = semantic.calculations if semantic is not None else []
    if not entries and not records and not members and not stubs and not calculations:
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
    catalog += [
        " ".join(
            part or ""
            for part in (
                row.name,
                row.model,
                row.kind,
                row.label,
                row.description,
                row.synonyms,
            )
        )
        for row in members
    ]
    catalog += [
        " ".join(
            part or "" for part in (row.name, row.model, row.backend, row.description)
        )
        for row in stubs
    ]
    catalog += [
        f"{calculation.key} {calculation.name} {calculation.description} "
        for calculation in calculations
    ]

    hits = lexical_rank(query, catalog)
    if not hits:
        return (
            f'Nothing in the semantic layer matches "{query}". '
            "Consider writing a SQL query."
        )
    blocks = []
    for hit in hits:
        if hit < len(entries):
            blocks.append(measure_schema_text(entries[hit], source_names=source_names))
            continue
        hit -= len(entries)
        if hit < len(records):
            blocks.append(definition_pool_text(records[hit], records))
            continue
        hit -= len(records)
        if hit < len(members):
            row = members[hit]
            assert semantic is not None
            blocks.append(
                member_pool_text(
                    row,
                    members,
                    source_names,
                    semantic.parameters.get((row.source, row.model)),
                )
            )
            continue
        hit -= len(members)
        if hit < len(stubs):
            blocks.append(stub_pool_text(stubs[hit], source_names))
            continue
        blocks.append(
            calculation_pool_text(calculations[hit - len(stubs)], source_names)
        )
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
    arguments: Mapping[str, Any] | None = None,
) -> ContentToolResult:
    """Compile and run a governed query over one table's definitions.

    The shape semantic layers converge on: metrics by dimensions with
    filters, plus simple column predicates. Names arrive as strings and are
    validated here, because the provider only ever sees `call_metrics`.
    Metrics may instead come from one of the warehouse's own semantic models,
    whose parameters `arguments` binds.
    """
    if not metrics:
        raise ValueError("`metrics` must contain at least one metric name.")
    defs = registry.for_source(label)
    hydrate(source, metrics)
    members = semantic_registry({label: source}).members
    unread = [s for s in source.semantic_stubs if s not in source.semantic_models]
    origins = {metric_origin(name, defs, members, unread) for name in metrics}
    if len(origins) > 1:
        raise ValueError(
            "Metrics in one call must come from either data-dict definitions or "
            "one native semantic model."
        )
    if origins == {"semantic_model"}:
        return _semantic_metrics(
            source, handles, members, metrics, dimensions, filters, where, arguments
        )
    if arguments:
        raise ValueError("`arguments` is supported only for native semantic metrics.")
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
    advert = handles.register_rows(rows) if handles is not None else None
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
    return tool_result(
        body,
        tag=Tag.A,
        title=TRUSTED_CALL.settled,
        markdown=f"```sql\n{sql}\n```\n\n{rows_to_markdown(rows)}",
        # Only the arguments the caller gave: an omitted one is not how the
        # query ran, unlike a measure argument explicitly set to null.
        html=measure_display_html(
            {
                name: value
                for name, value in (
                    ("metrics", metrics),
                    ("dimensions", dimensions),
                    ("filters", filters),
                )
                if value is not None
            },
            rows,
            from_query=True,
        ),
    )


def call_calculation(
    sources: Mapping[str, DataSource],
    label: str,
    handles: HandleStore | None,
    name: str,
    arguments: Mapping[str, Any] | None = None,
) -> ContentToolResult:
    """Run a verified query exactly as the warehouse model declares it.

    The query runs on the source `label` names, but is looked up among every
    source's, so a name on another source is listed when it is not found.
    """
    source = sources[label]
    hydrate(source, [name])
    calculation = resolve_calculation(calculations_registry(sources), name, label)
    # Verified queries take no arguments, so any given is unexpected.
    values = validate_arguments({}, dict(arguments or {}))
    rows = source._query_trusted(calculation.sql)
    advert = handles.register_rows(rows) if handles is not None else None
    body = "\n\n".join(part for part in (rows_to_markdown(rows), advert) if part)
    return tool_result(
        body,
        tag=Tag.A,
        title=TRUSTED_CALL.settled,
        markdown=f"```sql\n{calculation.sql}\n```\n\n{rows_to_markdown(rows)}",
        html=measure_display_html(values, rows, from_query=True),
    )


def _semantic_metrics(
    source: DataSource,
    handles: HandleStore | None,
    members: list[MemberRow],
    metrics: list[str],
    dimensions: list[str] | None,
    filters: list[str] | None,
    where: list[dict[str, Any]] | None,
    arguments: Mapping[str, Any] | None,
) -> ContentToolResult:
    """Run native metrics through the one semantic model they belong to."""
    metric_rows = resolve_members(metrics, members, "metric")
    models = list(dict.fromkeys(row.model for row in metric_rows))
    if len(models) != 1:
        raise ValueError(
            "Metrics in one call must belong to one native semantic model."
        )
    model = source.semantic_models[models[0]]
    on_model = [row for row in members if row.model == models[0]]
    dimension_rows = resolve_members(dimensions, on_model, "dimension")
    filter_rows = resolve_filters(filters, on_model)
    values = validate_arguments(model.parameters, dict(arguments or {}))
    if model.backend == databricks_semantic.BACKEND:
        # A metric view has no filter members, so `filter_rows` is empty here.
        sql = databricks_semantic.metric_sql(
            model, metric_rows, dimension_rows, where, on_model, list(values)
        )
    else:
        sql = metric_sql(
            model,
            metric_rows,
            dimension_rows,
            filter_rows,
            where,
            on_model,
            list(values),
        )
    params = {f"p{index}": value for index, value in enumerate(values.values())}
    rows = source._query_compiled(sql, params or None)
    advert = handles.register_rows(rows) if handles is not None else None
    body = "\n\n".join(part for part in (rows_to_markdown(rows), advert) if part)
    return tool_result(
        body,
        tag=Tag.A,
        title=TRUSTED_CALL.settled,
        markdown=f"```sql\n{sql}\n```\n\n{rows_to_markdown(rows)}",
        html=measure_display_html(
            {
                name: value
                for name, value in (
                    ("metrics", metrics),
                    ("dimensions", dimensions),
                    ("filters", filters),
                )
                if value is not None
            },
            rows,
            from_query=True,
        ),
    )


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
    """A string literal, written by the warehouse's own rule where it has one."""
    if dialect == "snowflake":
        return _snowflake._quote_string(value)
    if dialect == "databricks":
        return _databricks._quote_string(value)
    return exp.Literal.string(value).sql(dialect=dialect)

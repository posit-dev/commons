"""The tools an agent registers, and the condition each one has to earn.

Register only the tools the agent's composition earns: nothing about its
surface should imply operations it does not have. `pkg-r/R/tools.R` decides
the same thing for R, and `tests/shared/tool-registration.json` pins the
conditions and the tool descriptions both packages must agree on.

`build_commons_tools()` returns tool objects rather than registering them on a
chat client, so an agent's surface can be built and inspected before there is
a live conversation to attach it to.
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import Any

from chatlas import ContentToolResult, Tool
from chatlas.types import ToolAnnotations

from ._catalog import (
    CatalogAuthorizationError,
    Manifest,
    Relation,
    _databricks,
    _snowflake,
    check_session,
    ensure_queryable,
    search,
)
from ._citations import CitationRequest, tool_result
from ._context_layer import ContextLayer
from ._data_source import DataSource, TableId
from ._definitions import Registry, applied_text, expand_tokens, index_overflows
from ._display import (
    CONTEXT_SEARCH,
    DATA_RETRIEVAL,
    DISPLAY_EXTRA_KEY,
    TABLE_INSPECTION,
    TRUSTED_CALL,
    TRUSTED_SEARCH,
    tool_display,
    visible_result_note,
)
from ._frames import describe_frame, is_frame
from ._handles import HandleStore
from ._measures import Measure
from ._pool import call_metrics, search_pool_text
from ._provenance import TAG_EXTRA_KEY, Tag
from ._rows import frame_rows, render_value, rows_to_markdown
from ._sample_summary import SAMPLE_SUMMARY_HEADING, sample_summary

__all__ = [
    "FirstTouch",
    "ToolContext",
    "build_commons_tools",
    "catalog_searchable",
    "pool_searchable",
    "registry_has_metrics",
    "run_sql_description",
    "tool_description",
]

SAMPLE_ROWS = 5
CATALOG_SEARCH_LIMIT = 10
# As many items of a measure's list result as the model gets to read.
MAX_MEASURE_ITEMS = 20

_READ_ONLY: ToolAnnotations = {"readOnlyHint": True}


def _word_pattern(word: str) -> re.Pattern[str]:
    return re.compile(rf"(?<!\w){re.escape(word)}(?!\w)", re.IGNORECASE)


@dataclass
class FirstTouch:
    """Which tables' dictionary entries this conversation has already seen.

    `describe_table` and `run_sql` share one tracker, so a table's entry is
    put in front of the model once however the model first reached it, and is
    not re-delivered on every later query.
    """

    seen: set[tuple[str, str]] = field(default_factory=set)

    def touched(self, source: str, table: str) -> bool:
        return (source, table) in self.seen

    def mark(self, source: str, table: str) -> None:
        self.seen.add((source, table))


@dataclass
class ToolContext:
    """Everything the tool bodies reach for, in one place.

    Conversation-scoped state (the handle store, the citation request, the
    first-touch tracker) belongs to whoever builds the context, so several
    agents over the same layers do not share it.
    """

    sources: Mapping[str, DataSource]
    measures: Mapping[str, Measure] = field(default_factory=dict)
    definitions: Registry = field(default_factory=Registry)
    context_layer: ContextLayer | None = None
    handles: HandleStore = field(default_factory=HandleStore)
    citation_request: CitationRequest | None = None
    # Measure name to the arguments commons supplies, from resolve_injections.
    injections: Mapping[str, Mapping[str, Any]] = field(default_factory=dict)
    first_touch: FirstTouch = field(default_factory=FirstTouch)


# ---- registration conditions ---------------------------------------------


def pool_searchable(measures: Mapping[str, Measure], definitions: Registry) -> bool:
    """Whether the pool holds anything the system prompt does not already show.

    Measures are never listed in the prompt, and definitions past their index
    cap are not either; a search tool over a fully visible pool would only
    cost the model a round trip to confirm what it can already read.
    """
    return bool(measures) or index_overflows(definitions)


def registry_has_metrics(definitions: Registry) -> bool:
    """Whether any governed definition is a metric `call_metrics` could run."""
    return any(record.kind == "metric" for record in definitions.records)


def catalog_searchable(source: DataSource) -> bool:
    """Whether this source's catalog is too broad to list in the prompt."""
    return source.manifest is not None and source.manifest.searchable


def build_commons_tools(context: ToolContext) -> list[Tool]:
    """The tools this composition earns, ready to register on a chat client.

    The code-execution tool is not among them: it carries a worker process and
    a sandbox, so it is built separately and appended by its owner.
    """
    tools: list[Tool] = []
    if pool_searchable(context.measures, context.definitions):
        tools.append(_search_pool(context))
    if context.measures:
        tools.append(_call_measure(context))
    if registry_has_metrics(context.definitions):
        tools.append(_call_metrics(context))
    if any(catalog_searchable(source) for source in context.sources.values()):
        tools.append(_search_catalog(context))
    tools.extend(
        [
            _search_context(context),
            _describe_table(context),
            _run_sql(context),
        ]
    )
    return tools


# ---- schema helpers -------------------------------------------------------


def _string(description: str) -> dict[str, Any]:
    return {"type": "string", "description": description}


def _string_array(description: str) -> dict[str, Any]:
    return {"type": "array", "items": {"type": "string"}, "description": description}


def _parameters(
    properties: dict[str, Any],
    required: list[str],
    sources: Mapping[str, DataSource] | None = None,
) -> dict[str, Any]:
    """A tool's JSON schema, with the source argument added only if it is real.

    `sources` is passed by the tools that query one of them. With a single
    source there is nothing to choose, so the model never sees `source` at all
    rather than being asked for a value it cannot get wrong.
    """
    if sources is not None and len(sources) > 1:
        properties = {
            **properties,
            "source": {
                "type": "string",
                "enum": list(sources),
                "description": "The data source to use, as listed in the system prompt.",
            },
        }
        required = [*required, "source"]
    return {
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": False,
    }


def _tool(
    func: Callable[..., Any],
    name: str,
    description: str,
    parameters: dict[str, Any],
    title: str,
) -> Tool:
    return Tool(
        func=func,
        name=name,
        description=description,
        parameters=parameters,
        annotations={**_READ_ONLY, "title": title},
    )


def tool_description(tool: Tool) -> str:
    """What a tool tells the model it is for.

    chatlas keeps a tool's description inside the provider schema it builds,
    and `tests/shared/tool-registration.json` pins that text, so reading it
    back has one spelling rather than one per caller.
    """
    return str(tool.schema["function"]["description"])


def _resolve_source(
    sources: Mapping[str, DataSource], name: str | None
) -> tuple[str, DataSource]:
    if not sources:
        raise ValueError("This agent has no data sources.")
    if len(sources) == 1:
        return next(iter(sources.items()))
    if name is not None and name in sources:
        return name, sources[name]
    problem = (
        "source is required when an agent has several data sources."
        if name is None
        else f"No data source named {name!r}."
    )
    raise ValueError(f"{problem} Available sources: {', '.join(sources)}.")


# ---- search_pool ----------------------------------------------------------


def _search_pool(context: ToolContext) -> Tool:
    # The pool's blocks name their source only for an agent that has several.
    source_names = tuple(context.sources) if len(context.sources) > 1 else ()
    kinds = []
    if context.measures:
        kinds.append("measures (run with call_measure)")
    if context.definitions.records:
        kinds.append("governed definitions (apply as {{name}} tokens in run_sql)")

    def search_pool(query: str) -> ContentToolResult:
        return tool_result(
            search_pool_text(
                context.measures, context.definitions, query, source_names
            ),
            title=TRUSTED_SEARCH.settled,
        )

    return _tool(
        search_pool,
        "search_pool",
        f"Search the semantic layer's trusted calculations: {' and '.join(kinds)}. "
        "For every data question, use this before any other data tool, even if "
        "a table looks easy to query directly. Use the exact names it returns.",
        _parameters(
            {"query": _string("What you want to compute, in plain language.")},
            ["query"],
        ),
        TRUSTED_SEARCH.running,
    )


# ---- call_measure ---------------------------------------------------------


def _call_measure(context: ToolContext) -> Tool:
    def call_measure(name: str, arguments: str = "{}") -> ContentToolResult:
        record = context.measures.get(name)
        if record is None:
            available = (
                f"Registered measures: {', '.join(context.measures)}."
                if context.measures
                else "No measures are registered."
            )
            raise ValueError(f"No measure named {name!r}. {available}")
        args = record.validate_args(_parse_json_arguments(arguments))
        injected = context.injections.get(name, {})
        # A measure takes a source's connection by the source's own name, and
        # a board source has to have read its pins before that connection can
        # answer: the measure holds the connection, not the DataSource, so
        # the read-on-demand that query() does never fires for it.
        for argument in injected:
            source = context.sources.get(argument)
            if source is not None:
                source.ensure_loaded()
        value = record.func(**args, **injected)
        # A measure that built its own tool result — a plot, a displayable
        # table — has already said how it should look; commons only fills in
        # what it alone knows.
        if isinstance(value, ContentToolResult):
            return _finish_measure_result(value, context)
        advert = context.handles.register(value)
        body = "\n\n".join(
            part for part in (_format_measure_value(value), advert) if part
        )
        return tool_result(body, tag=Tag.A, title=TRUSTED_CALL.settled)

    return _tool(
        call_measure,
        "call_measure",
        "Run trusted calculations returned by search_pool. `arguments` is a "
        "JSON object using exactly the argument names from search_pool. Prefer "
        "a measure's own arguments when they can answer the question directly. "
        "Measure results may be displayed directly to the user. If a result "
        "says it is already visible, do not reproduce it in your reply; "
        "summarize or interpret the relevant results instead.",
        _parameters(
            {
                "name": _string(
                    "The measure name, exactly as returned by search_pool."
                ),
                "arguments": _string("A JSON object of the measure's arguments."),
            },
            ["name", "arguments"],
        ),
        TRUSTED_CALL.running,
    )


def _finish_measure_result(
    result: ContentToolResult, context: ToolContext
) -> ContentToolResult:
    """Fill in what commons knows about a result a measure built for itself.

    That is the trusted tag, a default title, the handle the values behind
    the display are reachable by, and the note that stops the model repeating
    a result the reader can already see. An errored result gets none of it:
    the model is sent the error rather than the value, so anything added to
    the value would never arrive.
    """
    extra = dict(result.extra or {})
    data = extra.pop("data", None)
    display = _titled(extra.get(DISPLAY_EXTRA_KEY))
    extra[DISPLAY_EXTRA_KEY] = display
    extra[TAG_EXTRA_KEY] = Tag.A
    result.extra = extra

    if result.error is None:
        parts = [_format_measure_value(result.value), context.handles.register(data)]
        if any(_display_field(display, name) is not None for name in _SHOWN_FIELDS):
            parts.insert(0, visible_result_note("measure result"))
        result.value = "\n\n".join(part for part in parts if part)
    return result


# The fields that put the result itself in front of the reader, rather than
# only a row saying the tool ran.
_SHOWN_FIELDS = ("html", "markdown", "text")


def _display_field(display: Any, name: str) -> Any:
    """Read one field off a display, however the measure chose to build it."""
    if isinstance(display, Mapping):
        return display.get(name)
    return getattr(display, name, None)


def _titled(display: Any) -> Any:
    """Give a display the default title, unless the measure chose its own."""
    if display is None:
        return tool_display(TRUSTED_CALL.settled)
    if isinstance(display, Mapping):
        return {"title": TRUSTED_CALL.settled, **display}
    if getattr(display, "title", None) is None:
        # A shinychat ToolResultDisplay, which its own documentation
        # recommends over the mapping commons builds.
        display.title = TRUSTED_CALL.settled
    return display


def _parse_json_arguments(arguments: Any) -> dict[str, Any]:
    """Read a measure's `arguments`, which a provider may send several ways.

    A mapping passes through, because some providers deliver the object rather
    than its JSON text, and an empty string is an empty object.
    """
    if arguments is None or arguments in ("", "{}"):
        return {}
    if isinstance(arguments, Mapping):
        return dict(arguments)
    parsed = json.loads(arguments)
    if not isinstance(parsed, dict):
        raise TypeError(
            f"arguments must be a JSON object, got {type(parsed).__name__}."
        )
    return parsed


def _format_measure_value(value: Any) -> str:
    """A measure's return value as text the model can read.

    A frame becomes a table when its rows can be read out of it, and its
    column summary otherwise, since a frame library commons does not know is
    still worth describing. A long list is cut off rather than printed in
    full, because a measure that returns one has a frame it could have
    returned instead.
    """
    if is_frame(value):
        rows = frame_rows(value)
        return rows_to_markdown(rows) if rows is not None else describe_frame(value)
    if isinstance(value, (list, tuple)):
        rendered = [render_value(item) for item in value[:MAX_MEASURE_ITEMS]]
        if len(value) > MAX_MEASURE_ITEMS:
            rendered.append(f"and {len(value) - MAX_MEASURE_ITEMS} more")
        return ", ".join(rendered)
    return render_value(value)


# ---- call_metrics ---------------------------------------------------------


def _call_metrics(context: ToolContext) -> Tool:
    named = (
        "the system prompt or search_pool"
        if pool_searchable(context.measures, context.definitions)
        else "the system prompt"
    )

    def call_metrics_tool(
        metrics: list[str],
        dimensions: list[str] | None = None,
        filters: list[str] | None = None,
        where: list[dict[str, Any]] | None = None,
        source: str | None = None,
    ) -> ContentToolResult:
        label, resolved = _resolve_source(context.sources, source)
        return call_metrics(
            context.definitions,
            resolved,
            label,
            context.handles,
            metrics=metrics,
            dimensions=dimensions,
            filters=filters,
            where=where,
        )

    return _tool(
        call_metrics_tool,
        "call_metrics",
        "Compute trusted calculations from governed metrics, optionally "
        "grouped and filtered. Metric, grouping, and filter names come from "
        f"{named}; commons compiles and runs the query.",
        _parameters(
            {
                "metrics": _string_array(
                    "Metric names to compute. All metrics in one call must "
                    "belong to the same table."
                ),
                "dimensions": _string_array(
                    "Derived or filter definition names, or documented column "
                    "names, to group by."
                ),
                "filters": _string_array("Governed filter names to apply."),
                "where": {
                    "type": "array",
                    "description": "Simple column predicates, e.g. a date range.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "column": _string("A documented column name."),
                            "op": {
                                "type": "string",
                                "enum": ["=", "!=", "<", "<=", ">", ">="],
                                "description": "Comparison operator.",
                            },
                            "value": _string(
                                "The comparison value; numbers and dates as "
                                "plain strings."
                            ),
                        },
                        "required": ["column", "op", "value"],
                        "additionalProperties": False,
                    },
                },
            },
            ["metrics"],
            context.sources,
        ),
        TRUSTED_CALL.running,
    )


# ---- search_catalog -------------------------------------------------------


def _search_catalog(context: ToolContext) -> Tool:
    def search_catalog(
        query: str, kinds: list[str] | None = None, source: str | None = None
    ) -> ContentToolResult:
        _, resolved = _resolve_source(context.sources, source)
        if not catalog_searchable(resolved):
            return tool_result(
                "This data source does not have a searchable catalog.",
                title=TRUSTED_SEARCH.settled,
            )
        results = _catalog_search(resolved, query, kinds)
        if not results:
            return tool_result(
                f'No catalog objects found for "{query}".',
                title=TRUSTED_SEARCH.settled,
            )
        lines = [
            f"- `{label}` ({relation.kind or 'unknown kind'}): "
            f"{relation.description or 'No description.'}"
            for label, relation in results.items()
        ]
        return tool_result("\n".join(lines), title=TRUSTED_SEARCH.settled)

    return _tool(
        search_catalog,
        "search_catalog",
        "Search a broad selected catalog by object name and description. "
        "Results are stable object names for describe_table.",
        _parameters(
            {
                "query": _string("The data you need, in plain language."),
                "kinds": _string_array("Optional object kinds such as table or view."),
            },
            ["query"],
            context.sources,
        ),
        TRUSTED_SEARCH.running,
    )


def _catalog_search(
    source: DataSource, query: str, kinds: list[str] | None
) -> dict[str, Relation]:
    check_session(source.backend, source.session)
    manifest = source.manifest
    if manifest is None:
        return {}
    # Only a warehouse has access answers to give, and only the objects a
    # namespace listing swept up are unverified, so nothing else is probed.
    probe = _queryable(source, manifest) if source.session is not None else None
    return search(manifest, query, kinds, limit=CATALOG_SEARCH_LIMIT, queryable=probe)


def _queryable(source: DataSource, manifest: Manifest) -> Callable[[str], bool]:
    def queryable(label: str) -> bool:
        relation = manifest.objects[label]
        try:
            ensure_queryable(
                source.backend, manifest, label, relation.identity or relation.id
            )
        except CatalogAuthorizationError:
            # A refusal is an answer: this relation is not the agent's to see,
            # so it is left out of the results. A transient or unreadable
            # failure is not an answer and is raised, because dropping it
            # would report a relation the agent has as one it does not.
            return False
        return True

    return queryable


# ---- search_context -------------------------------------------------------


def _search_context(context: ToolContext) -> Tool:
    def search_context(query: str) -> ContentToolResult:
        if context.context_layer is None:
            return tool_result(
                "No context layer is configured for this agent.",
                title=CONTEXT_SEARCH.settled,
            )
        hits = context.context_layer.search(query)
        body = "\n\n---\n\n".join(hits) if hits else f'No context found for "{query}".'
        return _with_citation_request(
            tool_result(body, title=CONTEXT_SEARCH.settled), context
        )

    return _tool(
        search_context,
        "search_context",
        "Search context for metric definitions, data notes, and table relationships.",
        _parameters(
            {"query": _string("What you need context about, in plain language.")},
            ["query"],
        ),
        CONTEXT_SEARCH.running,
    )


def _with_citation_request(
    result: ContentToolResult, context: ToolContext
) -> ContentToolResult:
    if context.citation_request is None:
        return result
    return context.citation_request.add_request(result)


# ---- describe_table -------------------------------------------------------


def _describe_table(context: ToolContext) -> Tool:
    def describe_table(table: str, source: str | None = None) -> ContentToolResult:
        label, resolved = _resolve_source(context.sources, source)
        return tool_result(
            _describe_table_text(resolved, label, table, context.first_touch),
            title=TABLE_INSPECTION.settled,
        )

    return _tool(
        describe_table,
        "describe_table",
        "Describe a table: columns, types, and sample rows. Use this before "
        "writing SQL against an unfamiliar table. The sample summary covers the "
        "sampled rows only, so it cannot show which values the whole table holds. "
        "Before you report that a value is absent, query for it.",
        _parameters(
            {"table": _string("The table name, as listed in the system prompt.")},
            ["table"],
            context.sources,
        ),
        TABLE_INSPECTION.running,
    )


def _describe_table_text(
    source: DataSource, label: str, table: str, tracker: FirstTouch
) -> str:
    check_session(source.backend, source.session)
    table_id = source.table_ids.get(table)
    if table_id is None:
        raise ValueError(
            f"No table named {table!r}. Available tables: {', '.join(source.tables)}."
        )
    ensure_queryable(source.backend, source.manifest, table, table_id)

    sample = source.query(
        f"SELECT * FROM {source.backend.quote(table_id)} LIMIT {SAMPLE_ROWS}"
    )
    relation = (source.relations or {}).get(table)
    schema = _relation_columns(source, table, table_id, relation)
    dictionary = source.dictionary
    entry = dictionary.tables.get(table) if dictionary is not None else None

    parts: list[str] = []
    if relation is not None and relation.kind:
        parts.append(f"Relation type: {relation.kind}.")
    if entry is None:
        # Without an entry the catalog's own prose is all there is to say.
        if relation is not None and relation.description:
            parts.append(relation.description)
        parts.append(f"Columns of `{table}`:\n\n{rows_to_markdown(schema)}")
    else:
        assert dictionary is not None
        columns = dictionary.columns_text(table, live=schema)
        parts.extend(
            dictionary.entry_parts(table, f"Columns of `{table}`:\n\n{columns}")
        )
    # A summary of the sample rather than the rows: five rows of values say
    # less about a column than its range, its missing count, and the values it
    # takes. The schema fixes the columns, so a table whose sample came back
    # empty is still described column by column.
    parts.append(
        f"{SAMPLE_SUMMARY_HEADING}\n\n"
        f"{sample_summary(sample, [str(found['column']) for found in schema])}"
    )

    tracker.mark(label, table)
    return "\n\n".join(parts)


def _relation_columns(
    source: DataSource, table: str, table_id: TableId, relation: Relation | None
) -> list[dict[str, Any]]:
    """A table's columns, asking the cheapest source that has them.

    A warehouse listing may already carry them; otherwise the warehouse is
    described once and the answer is kept on the relation, since the listing
    is what every later mention of the table reads from.
    """
    if relation is None:
        return source.backend.columns(table_id)
    if relation.columns:
        return relation.columns
    if _snowflake.is_snowflake(source.backend):
        columns = _snowflake.describe_relation(source.backend, table_id)
    elif _databricks.is_databricks(source.backend):
        columns = _databricks.describe_relation(source.backend, table_id)
    else:
        columns = source.backend.columns(table_id)
    relation.columns = columns
    return columns


# ---- run_sql --------------------------------------------------------------


def run_sql_description(
    definitions: Registry, measures: Mapping[str, Measure] | None = None
) -> str:
    """What `run_sql` tells the model it is for, given what else it can reach."""
    parts = ["Run a read-only SELECT query against a data source."]
    if measures:
        parts.append("Use this when no registered measure answers the question.")
    if definitions.records:
        parts.append(
            "Governed definitions can be written as {{name}} tokens anywhere "
            "in the SQL (or {{table::name}} when qualification is needed); "
            "each expands to its compiled SQL before the query runs."
        )
    return " ".join(parts)


def _run_sql(context: ToolContext) -> Tool:
    def run_sql(sql: str, source: str | None = None) -> ContentToolResult:
        label, resolved = _resolve_source(context.sources, source)
        expanded, applied = expand_tokens(sql, context.definitions.for_source(label))
        rows = resolved.query(expanded)
        body = "\n\n".join(
            part
            for part in (
                rows_to_markdown(rows),
                applied_text(applied),
                context.handles.register(rows),
                *_first_touch_entries(resolved, expanded, label, context.first_touch),
            )
            if part
        )
        return _with_citation_request(
            tool_result(body, tag=Tag.B, title=DATA_RETRIEVAL.settled), context
        )

    return _tool(
        run_sql,
        "run_sql",
        run_sql_description(context.definitions, context.measures),
        _parameters(
            {
                "sql": _string(
                    "A read-only SELECT query, in the data source's SQL dialect."
                )
            },
            ["sql"],
            context.sources,
        ),
        DATA_RETRIEVAL.running,
    )


# ---- the first-touch dictionary entries -----------------------------------


def _first_touch_entries(
    source: DataSource, sql: str, label: str, tracker: FirstTouch
) -> list[str]:
    """Entries for the tables this query touches that the model has not seen.

    Matching is by table name in the SQL text, which is reliable in a way
    column matching is not; a false positive appends a harmless note.
    """
    dictionary = source.dictionary
    if dictionary is None:
        return []
    entries: list[str] = []
    for table in source.tables:
        if tracker.touched(label, table):
            continue
        if not _table_mentioned(source, table, sql):
            continue
        entry = dictionary.entry_text(table)
        if not entry:
            continue
        tracker.mark(label, table)
        entries.append(entry)
    return entries


def _table_mentioned(source: DataSource, table: str, sql: str) -> bool:
    dictionary = source.dictionary
    entry = dictionary.tables.get(table) if dictionary is not None else None
    names = {table}
    if entry is not None and entry.authored_name:
        names.add(entry.authored_name)
    table_id = source.table_ids.get(table)
    if table_id is not None:
        # A qualified label is not what the SQL says; the bare relation name is.
        names.add(table_id.table)
    return any(_word_pattern(name).search(sql) for name in names)

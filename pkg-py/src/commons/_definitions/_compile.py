"""Binding source-independent export records to a source.

Export records stay source-independent until a source supplies the target
dialect. This module does the rest: it derives the grain metadata
`call_metrics` needs, refuses a metric no single SQL expression can express,
inlines each definition's sibling references into its SQL, and produces the
`ExportRecord` values the registry consumes.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import replace
from typing import Any

from ._emit_duckdb import emit_duckdb
from ._emit_sql import emit_sql
from ._export import DefinitionExport, Ir
from ._registry import ExportRecord

__all__ = ["attach_compiled_definitions", "mixed_grain"]

_TARGETS = {
    "duckdb": "SQL(duckdb)",
    "snowflake": "SQL(snowflake)",
    "databricks": "SQL(databricks)",
}


def mixed_grain(definitions: dict[str, DefinitionExport]) -> dict[str, bool]:
    """Which definitions mix row and aggregate grain, directly or inherited.

    `call_metrics` refuses a mix of row and aggregate definitions in one call,
    and the exported kind cannot answer this: a row expression can hold an
    aggregate child without becoming an aggregate itself. Inheritance is
    resolved to a fixed point because a reference chain can be any depth.
    """
    grain = {
        name: definition.ir is not None
        and definition.ir.shape == "row"
        and _has_aggregate(definition.ir)
        for name, definition in definitions.items()
    }
    while True:
        updated = {
            name: grain[name]
            or any(grain.get(reference, False) for reference in definition.definitions)
            for name, definition in definitions.items()
        }
        if updated == grain:
            return grain
        grain = updated


def _has_aggregate(ir: Ir) -> bool:
    if ir.shape == "agg":
        return True
    return any(_has_aggregate(child) for child in _children(ir))


def _children(ir: Ir) -> list[Ir]:
    """Every node one level down, wherever the parent hung it.

    A node's payload is a plain mapping, so a child can sit under a key, in a
    list, or in a mapping inside a list: `CASE` holds its branches as a list
    of condition-and-result pairs. Anything that stops at the first level it
    does not recognize walks part of the tree and silently skips the rest.
    """
    out: list[Ir] = []

    def collect(value: Any) -> None:
        if isinstance(value, Ir):
            out.append(value)
        elif isinstance(value, list):
            for item in value:
                collect(item)
        elif isinstance(value, dict):
            for item in value.values():
                collect(item)

    collect(dict(ir.attrs))
    return out


def _map_children(ir: Ir, transform: Callable[[Ir], Ir]) -> dict[str, Any]:
    """A copy of a node's payload with `transform` applied to every child."""

    def convert(value: Any) -> Any:
        if isinstance(value, Ir):
            return transform(value)
        if isinstance(value, list):
            return [convert(item) for item in value]
        if isinstance(value, dict):
            return {key: convert(item) for key, item in value.items()}
        return value

    return {key: convert(value) for key, value in ir.attrs.items()}


def attach_compiled_definitions(
    dictionary: Any,
    dialect: str,
    exposed: set[str] | None = None,
    bindings: dict[str, Any] | None = None,
) -> None:
    """Compile every governed definition for `dialect`, onto the dictionary.

    Called once a source is known, because the dialect decides the emitter.
    A dictionary with no definitions needs no emitter, so an unsupported
    dialect is only an error when there is something to lower.

    `exposed` names the source's tables. A definition on a table outside them
    would compile to SQL against a relation that is not there, so it is
    refused here rather than at `build_registry()`: by then the compiled
    records have already reached the dictionary's retrieval chunks. Prose
    about an unexposed table is left alone, since only a definition emits SQL.

    `bindings` is what a warehouse catalog import matched. With it, every
    column a definition names is rewritten to the spelling the warehouse
    reported, because the expression was written against the authored one.
    """
    exports: dict[str, dict[str, DefinitionExport]] = (
        getattr(dictionary, "definition_exports", None) or {}
    )
    if bindings is not None:
        _check_definitions_matched(exports, bindings)
    for table_name, entry in dictionary.tables.items():
        # A catalog import re-keys the dictionary to the warehouse's labels
        # and records what the author called each table, which is how its
        # exports are still found afterwards.
        authored = getattr(entry, "authored_name", None) or table_name
        definitions = exports.get(authored) or {}
        if not definitions:
            entry.compiled_definitions = []
            continue
        if exposed is not None and table_name not in exposed:
            raise ValueError(
                f"The data dictionary declares definitions on table "
                f"{table_name!r}, which the data source does not expose. "
                f"Exposed tables: {', '.join(sorted(exposed))}."
            )
        target = _TARGETS.get(dialect)
        if target is None:
            raise ValueError(
                f"Definitions on table {table_name!r} cannot be compiled for a "
                f"{dialect!r} data source. commons lowers definitions to "
                f"{', '.join(sorted(_TARGETS))}."
            )
        if bindings is not None:
            definitions = _bind_table(
                definitions, bindings["columns"].get(authored) or {}, table_name
            )
        entry.compiled_definitions = _compile_table(table_name, definitions, target)


def _check_definitions_matched(
    exports: dict[str, dict[str, DefinitionExport]], bindings: dict[str, Any]
) -> None:
    """Refuse a definition whose table the catalog selection left out.

    Compiling it is impossible and dropping it is worse than failing: the
    agent would be told about a governed definition that quietly is not there.
    """
    for authored, definitions in exports.items():
        if definitions and bindings["tables"].get(authored) is None:
            raise ValueError(
                f"Authored table {authored!r} declares definitions, and does "
                f"not match an exposed relation. Name it as the data source "
                f"selects it, or drop it from the data dictionary."
            )


def _bind_table(
    definitions: dict[str, DefinitionExport],
    columns: dict[str, str | None],
    table: str,
) -> dict[str, DefinitionExport]:
    """Rewrite every definition's expression to the discovered spelling.

    `DefinitionExport.columns`, the list of columns a definition reads, keeps
    the authored spelling: it describes the dictionary the author wrote,
    which is also what the R implementation leaves it as.
    """
    return {
        name: replace(
            definition,
            ir=None
            if definition.ir is None
            else _bind_ir(definition.ir, columns, name, table),
            selection=_bind_selection(definition.selection, columns, name, table),
        )
        for name, definition in definitions.items()
    }


def _bind_ir(ir: Ir, columns: dict[str, str | None], definition: str, table: str) -> Ir:
    attrs = _map_children(
        ir, lambda child: _bind_ir(child, columns, definition, table)
    )
    # A reference to a sibling definition is a name in the dictionary, not a
    # column in the warehouse, and is inlined later rather than bound.
    if ir.kind == "column" and ir.attrs.get("reference") != "definition":
        attrs["path"] = _bind_path(attrs["path"], columns, definition, table)
    # A COLUMNS(...) node carries the resolved selection alongside the copy
    # the export record holds. The emitters read the record's, but leaving a
    # stale one here would put two different answers in the same tree.
    if "selection" in attrs:
        attrs["selection"] = _bind_selection(
            attrs["selection"], columns, definition, table
        )
    return Ir(kind=ir.kind, type=ir.type, shape=ir.shape, attrs=attrs)


def _bind_selection(
    selection: dict[str, Any] | None,
    columns: dict[str, str | None],
    definition: str,
    table: str,
) -> dict[str, Any] | None:
    if selection is None:
        return None
    return {
        **selection,
        "columns": [
            {
                **column,
                "path": _bind_path(column["path"], columns, definition, table),
            }
            for column in selection["columns"]
        ],
    }


def _bind_path(
    path: Any, columns: dict[str, str | None], definition: str, table: str
) -> Any:
    """The physical spelling of the column a path leads with."""
    segments = list(path) if isinstance(path, list) else [path]
    physical = columns.get(segments[0])
    if physical is None:
        raise ValueError(
            f"Definition {definition!r} on table {table!r} references "
            f"authored column {segments[0]!r}, which is absent from the "
            f"selected relation."
        )
    segments[0] = physical
    return segments if isinstance(path, list) else segments[0]


def _compile_table(
    table: str, definitions: dict[str, DefinitionExport], target: str
) -> list[ExportRecord]:
    grain = mixed_grain(definitions)
    offenders = [
        name
        for name, definition in definitions.items()
        if grain[name] and definition.kind == "metric"
    ]
    if offenders:
        raise ValueError(
            f"Metric definition {offenders[0]!r} on table {table!r} cannot be "
            f"compiled into one SQL expression. Its dependency chain mixes row "
            f"and aggregate grain and would need a subquery rewrite."
        )
    markers = _reference_markers(definitions)
    emitted = {}
    for name, definition in definitions.items():
        if definition.ir is None:
            continue
        marked = _mark_references(definition.ir, markers)
        if target == "SQL(duckdb)":
            emitted[name] = emit_duckdb(marked, definition.selection)
            continue
        dialect = target[len("SQL(") : -1]
        result = emit_sql(marked, dialect, definition.selection)
        if result["error"] is not None:
            raise ValueError(
                f"Definition {name!r} on table {table!r} cannot be compiled "
                f"for {target}. {result['error']}"
            )
        emitted[name] = result
    composed = _compose(table, definitions, emitted, markers, _quote_for(target))
    return [
        ExportRecord(
            name=name,
            # Filled by the registry, which knows the source and the table it
            # was reached through.
            table=table,
            source="",
            kind=definition.kind,
            type=definition.type,
            expression=definition.expression,
            label=definition.label,
            description=definition.description,
            details=definition.details,
            columns=list(definition.columns),
            definitions=list(definition.definitions),
            sql=composed[name]["code"],
            target=target,
            notes=composed[name]["notes"],
            mixed_grain=grain[name],
        )
        for name, definition in definitions.items()
    ]


def _reference_markers(definitions: dict[str, DefinitionExport]) -> dict[str, str]:
    """A unique stand-in for each definition name, safe to substitute later.

    Composition works on the emitted SQL, so a reference has to be findable in
    it without colliding with a real identifier. Marking the reference before
    emitting rather than searching for the definition's own name afterwards is
    what makes that collision impossible.
    """
    used = set(definitions)
    for definition in definitions.values():
        used.update(definition.columns)
        if definition.ir is not None:
            used.update(_ir_identifiers(definition.ir))
    markers: dict[str, str] = {}
    for index, name in enumerate(definitions, start=1):
        marker = f"__commons_definition_reference_{index:03d}__"
        while marker in used or marker in markers.values():
            marker += "_"
        markers[name] = marker
    return markers


def _ir_identifiers(ir: Ir) -> set[str]:
    out: set[str] = set()
    if ir.kind == "column":
        out.update(ir.attrs.get("path") or [])
    for child in _children(ir):
        out |= _ir_identifiers(child)
    return out


def _mark_references(ir: Ir, markers: dict[str, str]) -> Ir:
    """Rename each sibling-definition reference to its marker."""
    attrs = _map_children(ir, lambda child: _mark_references(child, markers))
    if ir.kind == "column" and ir.attrs.get("reference") == "definition":
        path = list(attrs["path"])
        path[0] = markers[path[0]]
        attrs["path"] = path
    return Ir(kind=ir.kind, type=ir.type, shape=ir.shape, attrs=attrs)


def _quote_for(target: str) -> str:
    """How the target writes an identifier."""
    return "`" if target == "SQL(databricks)" else '"'


def _compose(
    table: str,
    definitions: dict[str, DefinitionExport],
    emitted: dict[str, dict[str, Any]],
    markers: dict[str, str],
    quote: str,
) -> dict[str, dict[str, Any]]:
    """Inline each definition's references, in dependency order."""
    composed: dict[str, dict[str, Any]] = {}
    pending = list(definitions)
    while pending:
        ready = [
            name
            for name in pending
            if all(reference in composed for reference in definitions[name].definitions)
        ]
        if not ready:
            raise ValueError(
                f"Definitions on table {table!r} cannot be composed because "
                f"their dependency graph is unresolved: "
                f"{', '.join(repr(name) for name in pending)}."
            )
        for name in ready:
            references = definitions[name].definitions
            replacements = {
                markers[reference]: composed[reference]["code"]
                for reference in references
            }
            notes = list(emitted[name]["notes"])
            for reference in references:
                notes.extend(composed[reference]["notes"])
            composed[name] = {
                "code": _substitute_identifiers(
                    emitted[name]["code"], replacements, quote
                ),
                "notes": sorted(set(notes)),
            }
        pending = [name for name in pending if name not in ready]
    return composed


def _substitute_identifiers(code: str, replacements: dict[str, str], quote: str) -> str:
    """Replace quoted marker identifiers with the SQL they stand for.

    `quote` is how the target writes an identifier, which is a backtick for
    Databricks and a double quote otherwise. Getting it wrong leaves the
    marker in the emitted SQL as a column that does not exist.

    A scan rather than a string replace, so a marker inside a string literal
    is left alone and a doubled quote is read as one literal character rather
    than the end of the identifier. The substituted SQL is parenthesised
    because it lands in the middle of an expression whose precedence it does
    not know.
    """
    if not replacements:
        return code
    out: list[str] = []
    index = 0
    while index < len(code):
        char = code[index]
        if char in ("'", quote):
            token, index = _take_quoted(code, index, char)
            if char == quote:
                name = token[1:-1].replace(quote * 2, quote)
                if name in replacements:
                    out.append(f"({replacements[name]})")
                    continue
            out.append(token)
            continue
        out.append(char)
        index += 1
    return "".join(out)


def _take_quoted(code: str, start: str | int, quote: str) -> tuple[str, int]:
    index = int(start) + 1
    while index < len(code):
        if code[index] == quote:
            if index + 1 < len(code) and code[index + 1] == quote:
                index += 2
                continue
            return code[int(start) : index + 1], index + 1
        index += 1
    raise ValueError("Generated SQL contains an unterminated quoted value.")

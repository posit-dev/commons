"""Binding source-independent export records to a source.

Export records stay source-independent until a source supplies the target
dialect. This module does the rest: it derives the grain metadata
`call_metrics` needs, refuses a metric no single SQL expression can express,
inlines each definition's sibling references into its SQL, and produces the
`ExportRecord` values the registry consumes.
"""

from __future__ import annotations

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
    out: list[Ir] = []
    for value in ir.attrs.values():
        if isinstance(value, Ir):
            out.append(value)
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, Ir):
                    out.append(item)
                elif isinstance(item, dict):
                    # A `CASE` branch is a mapping of condition and result.
                    out.extend(v for v in item.values() if isinstance(v, Ir))
        elif isinstance(value, dict):
            out.extend(item for item in value.values() if isinstance(item, Ir))
    return out


def attach_compiled_definitions(
    dictionary: Any, dialect: str, exposed: set[str]
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

    Nothing is assigned until every table compiles, so a refusal leaves the
    dictionary untouched and the caller can attach it to another source.
    """
    exports: dict[str, dict[str, DefinitionExport]] = (
        getattr(dictionary, "definition_exports", None) or {}
    )
    compiled: dict[str, list[ExportRecord]] = {}
    for table_name in dictionary.tables:
        definitions = exports.get(table_name) or {}
        if not definitions:
            compiled[table_name] = []
            continue
        if table_name not in exposed:
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
        compiled[table_name] = _compile_table(table_name, definitions, target)
    for table_name, entry in dictionary.tables.items():
        entry.compiled_definitions = compiled[table_name]


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
    composed = _compose(table, definitions, emitted, markers)
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
    attrs: dict[str, Any] = {}
    for key, value in ir.attrs.items():
        if isinstance(value, Ir):
            attrs[key] = _mark_references(value, markers)
        elif isinstance(value, list):
            attrs[key] = [
                _mark_references(item, markers)
                if isinstance(item, Ir)
                # A `CASE` branch is a mapping of condition and result.
                else (
                    {
                        inner_key: _mark_references(inner, markers)
                        if isinstance(inner, Ir)
                        else inner
                        for inner_key, inner in item.items()
                    }
                    if isinstance(item, dict)
                    else item
                )
                for item in value
            ]
        elif isinstance(value, dict):
            attrs[key] = {
                inner_key: _mark_references(inner, markers)
                if isinstance(inner, Ir)
                else inner
                for inner_key, inner in value.items()
            }
        else:
            attrs[key] = value
    if ir.kind == "column" and ir.attrs.get("reference") == "definition":
        path = list(attrs["path"])
        path[0] = markers[path[0]]
        attrs["path"] = path
    return Ir(kind=ir.kind, type=ir.type, shape=ir.shape, attrs=attrs)


def _compose(
    table: str,
    definitions: dict[str, DefinitionExport],
    emitted: dict[str, dict[str, Any]],
    markers: dict[str, str],
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
            # Unreachable while phase 1 rejects reference cycles; this guards
            # a caller that builds export records by hand.
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
                "code": _substitute_identifiers(emitted[name]["code"], replacements),
                "notes": sorted(set(notes)),
            }
        pending = [name for name in pending if name not in ready]
    return composed


def _substitute_identifiers(code: str, replacements: dict[str, str]) -> str:
    """Replace quoted marker identifiers with the SQL they stand for.

    A scan rather than a string replace, so a marker appearing inside a string
    literal is left alone. The substituted SQL is parenthesised because it
    lands in the middle of an expression whose precedence it does not know.
    """
    if not replacements:
        return code
    out: list[str] = []
    index = 0
    while index < len(code):
        char = code[index]
        if char in ("'", '"'):
            token, index = _take_quoted(code, index, char)
            if char == '"':
                name = token[1:-1].replace('""', '"')
                if name in replacements:
                    out.append(f"({replacements[name]})")
                    continue
            out.append(token)
            continue
        out.append(char)
        index += 1
    return "".join(out)


def _take_quoted(code: str, start: int, quote: str) -> tuple[str, int]:
    index = start + 1
    while index < len(code):
        if code[index] == quote:
            if index + 1 < len(code) and code[index + 1] == quote:
                index += 2
                continue
            return code[start : index + 1], index + 1
        index += 1
    raise ValueError("Generated SQL contains an unterminated quoted value.")

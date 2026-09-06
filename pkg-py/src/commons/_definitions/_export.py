"""Type checking, kind inference, and reference resolution.

A temporary, definition-only implementation of the contract produced by
`data-dict export-spec`, against tidyverse/data-dict at
d950c5ac90d0ab939d330600f3a5ee1bfde0f604.

A definition's `expr` is written in data-dict's typed expression language, not
in the SQL dialect of the attached source, so it cannot be run as authored. It
is parsed, type-checked against the dictionary, given an inferred kind and
value type, and its direct column and sibling-definition references resolved.
The type-checked expression is then lowered to DuckDB SQL, with notes where
DuckDB's semantics differ from data-dict's.

Conformance against the data-dict binary is the authority here, not this code
and not its R counterpart in `pkg-r/R/definition-export.R`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import UTC, date, datetime
from typing import Any

import re2

from ._emit_duckdb import emit_duckdb
from ._expression import Node, parse_expression

__all__ = ["DefinitionExport", "TableExport", "export_spec"]

_SHAPE_ORDER = {"const": 1, "agg": 2, "row": 3}
_EXPORTED_TYPES = frozenset(
    {"number", "string", "boolean", "date", "datetime", "interval"}
)
_INTERVAL_UNITS = frozenset({"seconds", "minutes", "hours", "days", "weeks"})
_TEMPORAL = frozenset({"date", "datetime"})

# RE2 logs every failed compile to stderr unless told not to; a refused
# pattern is reported by the ValueError in `_validate_regex`, not by log spew.
_RE2_OPTIONS = re2.Options()
_RE2_OPTIONS.log_errors = False

_DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
_DATETIME = re.compile(
    r"^([0-9]{4}-[0-9]{2}-[0-9]{2})[Tt]"
    r"([0-9]{2}:[0-9]{2}:[0-9]{2})"
    r"(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})?$"
)


@dataclass
class Ir:
    """A type-checked expression node.

    Mirrors the AST node it came from and adds the inferred `type` and `shape`.
    `kind` may differ from the node's: a `COLUMNS(...)` node becomes `selected`,
    and a string literal that coerces to a date becomes `date`.
    """

    kind: str
    type: str
    shape: str
    attrs: dict[str, Any] = field(default_factory=dict)


@dataclass
class DefinitionExport:
    """One definition's export record, with its DuckDB lowering."""

    name: str
    label: str | None
    description: str | None
    details: str | None
    todo: str | None
    expression: str
    kind: str
    type: str | None
    columns: list[str]
    definitions: list[str]
    # The DuckDB lowering and its conformance notes, filled during resolution.
    translations: list[dict[str, Any]] = field(default_factory=list)
    ir: Ir | None = None
    shape: str = "row"
    selection: dict[str, Any] | None = None
    selection_count: int = 0


@dataclass
class TableExport:
    name: str
    definitions: dict[str, DefinitionExport]


@dataclass
class _Column:
    type: str
    fields: dict[str, _Column] = field(default_factory=dict)


class _State:
    """Per-definition counters for the one-selection rule."""

    def __init__(self) -> None:
        self.selection: dict[str, Any] | None = None
        self.selection_count = 0
        self.definition_selection_count = 0


@dataclass
class _Signature:
    arities: tuple[int, ...]
    ret: str
    types: tuple[str, ...] = ()
    aggregate: bool = False
    unconstrained: bool = False


_SIGNATURES: dict[str, _Signature] = {
    "length": _Signature((1,), "number", ("string",)),
    "lower": _Signature((1,), "string", ("string",)),
    "upper": _Signature((1,), "string", ("string",)),
    "trim": _Signature((1,), "string", ("string",)),
    "starts_with": _Signature((2,), "boolean", ("string",)),
    "ends_with": _Signature((2,), "boolean", ("string",)),
    "abs": _Signature((1,), "number", ("number",)),
    "floor": _Signature((1,), "number", ("number",)),
    "ceil": _Signature((1,), "number", ("number",)),
    "round": _Signature((1, 2), "number", ("number",)),
    "mod": _Signature((2,), "number", ("number",)),
    "is_finite": _Signature((1,), "boolean", ("number",)),
    "is_infinite": _Signature((1,), "boolean", ("number",)),
    "is_nan": _Signature((1,), "boolean", ("number",)),
    "min": _Signature(
        (1,), "same", ("number", "string", "date", "datetime"), aggregate=True
    ),
    "max": _Signature(
        (1,), "same", ("number", "string", "date", "datetime"), aggregate=True
    ),
    "sum": _Signature((1,), "number", ("number",), aggregate=True),
    "avg": _Signature((1,), "number", ("number",), aggregate=True),
    "count": _Signature((1,), "number", aggregate=True, unconstrained=True),
    "row_count": _Signature((0,), "number", aggregate=True, unconstrained=True),
    "count_distinct": _Signature(
        (1,), "number", ("number", "string", "date", "datetime"), aggregate=True
    ),
    "any": _Signature((1,), "boolean", ("boolean",), aggregate=True),
    "all": _Signature((1,), "boolean", ("boolean",), aggregate=True),
}


def export_spec(raw: Any) -> dict[str, TableExport]:
    """Type-check every governed definition in a data dictionary."""
    raw = raw or {}
    tables = _named_entries(raw.get("tables"), "table")
    return {name: _export_table(name, table) for name, table in tables.items()}


def _export_table(table_name: str, table: dict[str, Any]) -> TableExport:
    columns = _named_entries(table.get("columns"), "column")
    definitions = _named_entries(table.get("definitions"), "definition")
    collisions = [name for name in definitions if name in columns]
    if collisions:
        raise ValueError(
            f"Definitions on table {table_name!r} share names with columns: "
            f"{', '.join(repr(name) for name in collisions)}."
        )
    column_env = {name: _column_descriptor(name, col) for name, col in columns.items()}
    envelopes = _prepare_envelopes(definitions, table_name)
    references = {
        name: _direct_references(
            envelope["ast"], set(envelopes), set(column_env)
        ).definitions
        for name, envelope in envelopes.items()
    }

    # Definitions resolve in dependency order rather than authored order, so a
    # definition may be written before the sibling it uses. A round that can
    # resolve nothing means the remainder reference each other.
    resolved: dict[str, DefinitionExport] = {}
    pending = list(envelopes)
    while pending:
        ready = [
            name for name in pending if all(ref in resolved for ref in references[name])
        ]
        if not ready:
            raise ValueError(
                f"Definitions on table {table_name!r} reference each other in a "
                f"cycle: {', '.join(repr(name) for name in pending)}."
            )
        for name in ready:
            resolved[name] = _resolve_one(
                envelopes[name], table_name, column_env, resolved, set(envelopes)
            )
        pending = [name for name in pending if name not in ready]

    return TableExport(
        name=table_name,
        definitions={name: resolved[name] for name in envelopes},
    )


def _prepare_envelopes(
    definitions: dict[str, Any], table: Any
) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for name, definition in definitions.items():
        expression = definition.get("expr")
        if not isinstance(expression, str) or not expression.strip():
            raise ValueError(
                f"Definition {name!r} on table {table!r} needs a non-empty expr."
            )
        for key in ("label", "description", "details", "todo"):
            value = definition.get(key)
            if value is not None and not isinstance(value, str):
                raise ValueError(
                    f"Definition {name!r} on table {table!r} has a non-string {key}."
                )
        try:
            ast = parse_expression(expression)
        except ValueError as error:
            raise ValueError(
                f"Definition {name!r} on table {table!r} has an invalid "
                f"expression. {error}"
            ) from error
        out[name] = {**definition, "name": name, "ast": ast}
    return out


def _resolve_one(
    definition: dict[str, Any],
    table: Any,
    columns: dict[str, _Column],
    resolved: dict[str, DefinitionExport],
    definition_names: set[str],
) -> DefinitionExport:
    name = definition["name"]
    state = _State()
    env = {"columns": columns, "definitions": resolved}
    try:
        ir = _check_node(definition["ast"], env, state)
    except ValueError as error:
        raise ValueError(
            f"Definition {name!r} on table {table!r} does not type-check. {error}"
        ) from error

    total_selections = state.selection_count + state.definition_selection_count
    if total_selections > 1:
        raise ValueError(
            f"Definition {name!r} on table {table!r} recursively uses more than "
            f"one COLUMNS(...) selection."
        )
    if total_selections > 0 and ir.type not in ("boolean", "any"):
        raise ValueError(
            f"Definition {name!r} on table {table!r} uses COLUMNS(...) but is "
            f"not a boolean filter."
        )
    if ir.kind == "selected":
        _require_selection(state.selection, ("boolean",), "a filter")
    if ir.type == "unknown":
        raise ValueError(
            f"Definition {name!r} on table {table!r} has no inferred type."
        )

    emitted = emit_duckdb(ir, state.selection)
    references = _direct_references(
        definition["ast"], definition_names, set(columns), columns
    )
    if ir.shape in ("agg", "const"):
        kind = "metric"
    elif ir.type == "boolean":
        kind = "filter"
    else:
        kind = "derived"
    return DefinitionExport(
        name=name,
        label=definition.get("label"),
        description=definition.get("description"),
        details=definition.get("details"),
        todo=definition.get("todo"),
        expression=definition["expr"],
        kind=kind,
        type=ir.type if ir.type in _EXPORTED_TYPES else None,
        columns=references.columns,
        definitions=references.definitions,
        translations=[
            {
                "target": "SQL(duckdb)",
                "code": emitted["code"],
                "error": None,
                "notes": emitted["notes"],
            }
        ],
        ir=ir,
        shape=ir.shape,
        selection=state.selection,
        selection_count=total_selections,
    )


def _ir(
    node: Node, type_: str, shape: str, kind: str | None = None, **attrs: Any
) -> Ir:
    merged = {**node.attrs, **attrs}
    return Ir(kind=kind or node.kind, type=type_, shape=shape, attrs=merged)


def _check_node(node: Node, env: dict[str, Any], state: _State) -> Ir:
    kind = node.kind
    if kind == "number":
        return _ir(node, "number", "const")
    if kind == "string":
        return _ir(node, "string", "const")
    if kind == "boolean":
        return _ir(node, "boolean", "const")
    if kind == "null":
        return _ir(node, "any", "const")
    if kind == "now":
        return _ir(node, "datetime", "const")
    if kind == "column":
        return _check_reference(node, env, state)
    if kind == "columns":
        selection = _resolve_selection(node.attrs["selector"], env["columns"])
        state.selection_count += 1
        if state.selection_count > 1:
            raise ValueError("An expression may use at most one COLUMNS(...).")
        state.selection = selection
        return _ir(node, "any", "row", kind="selected", selection=selection)
    if kind in ("negate", "not"):
        operand = _check_node(node.attrs["operand"], env, state)
        if kind == "negate":
            _require(operand, ("number",), "negation")
            return _ir(node, "number", operand.shape, operand=operand)
        _require(operand, ("boolean",), "`NOT`")
        return _ir(node, "boolean", operand.shape, operand=operand)
    if kind in ("and", "or"):
        lhs = _check_node(node.attrs["lhs"], env, state)
        rhs = _check_node(node.attrs["rhs"], env, state)
        _require(lhs, ("boolean",), "a logical operator")
        _require(rhs, ("boolean",), "a logical operator")
        return _ir(node, "boolean", _shape_max(lhs.shape, rhs.shape), lhs=lhs, rhs=rhs)
    if kind == "arithmetic":
        return _check_arithmetic(node, env, state)
    if kind == "compare":
        lhs = _check_node(node.attrs["lhs"], env, state)
        rhs = _check_node(node.attrs["rhs"], env, state)
        lhs, rhs = _comparable_ir(lhs, rhs)
        return _ir(node, "boolean", _shape_max(lhs.shape, rhs.shape), lhs=lhs, rhs=rhs)
    if kind == "is_null":
        operand = _check_node(node.attrs["operand"], env, state)
        return _ir(node, "boolean", operand.shape, operand=operand)
    if kind == "between":
        return _check_between(node, env, state)
    if kind == "in":
        return _check_in(node, env, state)
    if kind in ("like", "similar"):
        operand = _check_node(node.attrs["operand"], env, state)
        pattern = _check_node(node.attrs["pattern"], env, state)
        _require(operand, ("string",), f"`{kind.upper()}`")
        _require(pattern, ("string",), f"a `{kind.upper()}` pattern")
        if kind == "similar" and pattern.kind == "string":
            _validate_regex(pattern.attrs["value"])
        return _ir(
            node,
            "boolean",
            _shape_max(operand.shape, pattern.shape),
            operand=operand,
            pattern=pattern,
        )
    if kind == "interval":
        n = _check_node(node.attrs["n"], env, state)
        _require(n, ("number",), "`INTERVAL`")
        unit = node.attrs["unit"]
        if unit not in _INTERVAL_UNITS:
            raise ValueError(
                f"{unit!r} is not an interval unit; use seconds, minutes, "
                f"hours, days, or weeks."
            )
        return _ir(node, "interval", n.shape, n=n)
    if kind == "function":
        return _check_function(node, env, state)
    if kind == "case":
        return _check_case(node, env, state)
    raise ValueError(f"Unknown expression node {kind!r}.")


def _check_arithmetic(node: Node, env: dict[str, Any], state: _State) -> Ir:
    lhs = _check_node(node.attrs["lhs"], env, state)
    rhs = _check_node(node.attrs["rhs"], env, state)
    # A date or datetime plus or minus an interval shifts in time rather than
    # doing arithmetic, and yields a datetime.
    temporal_shift = node.attrs["op"] in ("+", "-") and (
        (lhs.type in _TEMPORAL and rhs.type in ("interval", "any"))
        or (rhs.type in _TEMPORAL and lhs.type in ("interval", "any"))
    )
    if temporal_shift:
        type_ = "datetime"
    else:
        _require(lhs, ("number",), "arithmetic")
        _require(rhs, ("number",), "arithmetic")
        type_ = "number"
    return _ir(node, type_, _shape_max(lhs.shape, rhs.shape), lhs=lhs, rhs=rhs)


def _check_between(node: Node, env: dict[str, Any], state: _State) -> Ir:
    operand = _check_node(node.attrs["operand"], env, state)
    lo = _check_node(node.attrs["lo"], env, state)
    hi = _check_node(node.attrs["hi"], env, state)
    coerced_operand, lo = _comparable_ir(operand, lo)
    _comparable_ir(operand, hi)
    coerced_operand, hi = _coerce_temporal_pair(coerced_operand, hi)
    shape = _shape_max(coerced_operand.shape, lo.shape, hi.shape)
    return _ir(node, "boolean", shape, operand=coerced_operand, lo=lo, hi=hi)


def _check_in(node: Node, env: dict[str, Any], state: _State) -> Ir:
    operand = _check_node(node.attrs["operand"], env, state)
    items = [_check_node(item, env, state) for item in node.attrs["items"]]
    items = [_comparable_ir(operand, item)[1] for item in items]
    if items:
        operand = _coerce_temporal(operand, items[0].type)
    shape = _shape_max(operand.shape, *[item.shape for item in items])
    return _ir(node, "boolean", shape, operand=operand, items=items)


def _check_case(node: Node, env: dict[str, Any], state: _State) -> Ir:
    whens = []
    shapes: list[str] = []
    types: list[str] = []
    for branch in node.attrs["whens"]:
        condition = _check_node(branch["condition"], env, state)
        result = _check_node(branch["result"], env, state)
        _require(condition, ("boolean",), "a `CASE` condition")
        whens.append({"condition": condition, "result": result})
        shapes.extend([condition.shape, result.shape])
        types.append(result.type)
    otherwise = None
    if node.attrs["otherwise"] is not None:
        otherwise = _check_node(node.attrs["otherwise"], env, state)
        shapes.append(otherwise.shape)
        types.append(otherwise.type)
    return _ir(
        node,
        _common_type(types),
        _shape_max(*shapes),
        whens=whens,
        otherwise=otherwise,
    )


def _check_reference(node: Node, env: dict[str, Any], state: _State) -> Ir:
    path = node.attrs["path"]
    columns: dict[str, _Column] = env["columns"]
    if len(path) == 1 and path[0] not in columns:
        definition = env["definitions"].get(path[0])
        if definition is None:
            raise ValueError(f"Column {path[0]!r} not found.")
        # A selection reached through a sibling still counts against the
        # one-selection rule.
        state.definition_selection_count += definition.selection_count
        return _ir(
            node,
            definition.type or "any",
            definition.shape or "row",
            reference="definition",
        )
    column = columns.get(path[0])
    if column is None:
        raise ValueError(f"Column {path[0]!r} not found.")
    current = column
    for index in range(1, len(path)):
        prefix = ".".join(path[:index])
        if current.type == "list":
            raise ValueError(
                f"{prefix!r} is a list, whose elements cannot be referenced."
            )
        if current.type != "struct":
            raise ValueError(f"{prefix!r} is not a struct.")
        nested = current.fields.get(path[index])
        if nested is None:
            raise ValueError(f"Struct {prefix!r} has no field {path[index]!r}.")
        current = nested
    return _ir(node, current.type, "row", reference="column")


def _check_function(node: Node, env: dict[str, Any], state: _State) -> Ir:
    name = node.attrs["name"]
    signature = _SIGNATURES.get(name)
    if signature is None:
        raise ValueError(f"Unknown function {name!r}.")
    args_nodes = node.attrs["args"]
    if len(args_nodes) not in signature.arities:
        expected = " or ".join(str(arity) for arity in signature.arities)
        raise ValueError(
            f"{name.upper()}() takes {expected} argument(s), not {len(args_nodes)}."
        )
    args = [_check_node(arg, env, state) for arg in args_nodes]
    if not signature.unconstrained:
        for arg in args:
            _require(arg, signature.types, f"`{name.upper()}`")
    if signature.aggregate and any(arg.shape == "agg" for arg in args):
        raise ValueError(
            f"{name.upper()}() cannot aggregate an expression that is already "
            f"aggregated."
        )
    type_ = (args[0].type or "any") if signature.ret == "same" else signature.ret
    shape = "agg" if signature.aggregate else _shape_max(*[arg.shape for arg in args])
    return _ir(node, type_, shape, args=args)


def _comparable_ir(lhs: Ir, rhs: Ir) -> tuple[Ir, Ir]:
    if lhs.kind == "selected":
        _require_selection_comparable(lhs.attrs["selection"], rhs)
    if rhs.kind == "selected":
        _require_selection_comparable(rhs.attrs["selection"], lhs)
    lhs, rhs = _coerce_temporal_pair(lhs, rhs)
    if not _types_comparable(lhs.type, rhs.type):
        raise ValueError(f"Cannot compare {lhs.type!r} with {rhs.type!r}.")
    return lhs, rhs


def _coerce_temporal_pair(lhs: Ir, rhs: Ir) -> tuple[Ir, Ir]:
    lhs_type, rhs_type = lhs.type, rhs.type
    return _coerce_temporal(lhs, rhs_type), _coerce_temporal(rhs, lhs_type)


def _coerce_temporal(ir: Ir, target: str) -> Ir:
    """Read a string literal as a date or datetime when compared with one."""
    if ir.kind != "string":
        return ir
    value = ir.attrs.get("value")
    if target == "date" and _is_date(value):
        return Ir("date", "date", ir.shape, dict(ir.attrs))
    if target == "datetime":
        normalized = _as_datetime(value)
        if normalized is not None:
            return Ir(
                "datetime", "datetime", ir.shape, {**ir.attrs, "value": normalized}
            )
    return ir


def _require_selection_comparable(selection: dict[str, Any], other: Ir) -> None:
    for column in selection["columns"]:
        if column["type"] == "unknown":
            raise ValueError(f"Column {column['name']!r} has no declared type.")
        other_value = _coerce_temporal(other, column["type"])
        if not _types_comparable(column["type"], other_value.type):
            raise ValueError(
                f"Column {column['name']!r} cannot be compared with {other.type!r}."
            )


def _types_comparable(lhs: str, rhs: str) -> bool:
    if lhs in ("struct", "list") or rhs in ("struct", "list"):
        return False
    return (
        lhs in ("any", rhs) or rhs == "any" or (lhs in _TEMPORAL and rhs in _TEMPORAL)
    )


def _require(ir: Ir, types: tuple[str, ...], context: str) -> None:
    if ir.kind == "selected":
        _require_selection(ir.attrs["selection"], types, context)
        return
    if ir.type == "unknown":
        path = ".".join(ir.attrs.get("path") or ["value"])
        raise ValueError(f"{path!r} has no declared type.")
    if ir.type not in ("any", *types):
        expected = " or ".join(repr(item) for item in types)
        raise ValueError(f"{context} expects {expected}, not {ir.type!r}.")


def _require_selection(
    selection: dict[str, Any] | None, types: tuple[str, ...], context: str
) -> None:
    for column in (selection or {"columns": []})["columns"]:
        if column["type"] == "unknown":
            raise ValueError(f"Column {column['name']!r} has no declared type.")
        if column["type"] not in ("any", *types):
            expected = " or ".join(repr(item) for item in types)
            raise ValueError(
                f"{context} expects {expected}, but column {column['name']!r} is "
                f"{column['type']!r}."
            )


def _resolve_selection(
    selector: dict[str, Any], columns: dict[str, _Column]
) -> dict[str, Any]:
    names = list(columns)
    if selector["kind"] == "regex":
        pattern = selector["pattern"]
        _validate_regex(pattern)
        names = _match_columns(pattern, names)
    if selector["kind"] == "list":
        missing = [name for name in selector["names"] if name not in names]
        if missing:
            raise ValueError(
                f"Columns not found: {', '.join(repr(name) for name in missing)}."
            )
        names = selector["names"]
    return {
        "form": selector["kind"],
        "pattern": selector.get("pattern"),
        "columns": [
            {"name": name, "path": name, "type": columns[name].type} for name in names
        ],
    }


def _validate_regex(pattern: str) -> str:
    """Refuse a pattern data-dict's engine would refuse.

    data-dict decides what a pattern means, using Rust's `regex`. commons
    cannot ask it at runtime, so it asks the closest engine with a maintained
    binding: RE2 and Rust's `regex` are both finite-automata engines, so they
    agree on rejecting lookaround and backreferences and on accepting Unicode
    classes, `\\z` and POSIX classes. Python's `re` disagrees with both, in
    both directions, and no amount of pre-processing turns it into a proxy
    for them.

    RE2 is close to Rust's `regex` but not identical, and this does not
    claim to know every difference. The ones found so far all fail closed
    and none changes what a definition matches: extended mode `(?x)` and
    CRLF-aware multiline `(?R)`. Closing the gap needs a Rust `regex`
    binding rather than more translation, which three reviews showed does
    not converge.
    """
    try:
        re2.compile(pattern, _RE2_OPTIONS)
    except re2.error as error:
        raise ValueError(
            f"Invalid data-dict regular expression {pattern!r}."
        ) from error
    return pattern


def _match_columns(pattern: str, names: list[str]) -> list[str]:
    """Column names the pattern matches, in the order the table declares them."""
    compiled = re2.compile(pattern, _RE2_OPTIONS)
    return [name for name in names if compiled.search(name)]


@dataclass
class _References:
    columns: list[str]
    definitions: list[str]


def _direct_references(
    ast: Node,
    definition_names: set[str],
    column_names: set[str],
    columns: dict[str, _Column] | None = None,
) -> _References:
    out = _References(columns=[], definitions=[])

    def visit(node: Node) -> None:
        if node.kind == "column":
            path = node.attrs["path"]
            if (
                len(path) == 1
                and path[0] in definition_names
                and path[0] not in column_names
            ):
                _append_unique(out.definitions, path[0])
            else:
                _append_unique(out.columns, ".".join(path))
        if node.kind == "columns" and columns is not None:
            selected = _resolve_selection(node.attrs["selector"], columns)
            names = [column["name"] for column in selected["columns"]]
            if node.attrs["selector"]["kind"] != "list":
                # An explicit list is taken at its word; a wildcard or regex
                # only contributes columns whose type is known.
                names = [name for name in names if columns[name].type != "unknown"]
            for name in names:
                _append_unique(out.columns, name)

    _walk(ast, visit)
    return out


def _walk(node: Node, visit: Any) -> None:
    visit(node)
    kind = node.kind
    attrs = node.attrs
    children: list[Node]
    if kind in ("negate", "not", "is_null"):
        children = [attrs["operand"]]
    elif kind in ("and", "or", "arithmetic", "compare"):
        children = [attrs["lhs"], attrs["rhs"]]
    elif kind == "between":
        children = [attrs["operand"], attrs["lo"], attrs["hi"]]
    elif kind == "in":
        children = [attrs["operand"], *attrs["items"]]
    elif kind in ("like", "similar"):
        children = [attrs["operand"], attrs["pattern"]]
    elif kind == "interval":
        children = [attrs["n"]]
    elif kind == "function":
        children = list(attrs["args"])
    elif kind == "case":
        children = []
        for branch in attrs["whens"]:
            children.extend([branch["condition"], branch["result"]])
        if attrs["otherwise"] is not None:
            children.append(attrs["otherwise"])
    else:
        children = []
    for child in children:
        _walk(child, visit)


def _named_entries(entries: Any, what: str) -> dict[str, Any]:
    if not entries:
        return {}
    if not isinstance(entries, list):
        raise TypeError(f"The data dictionary's {what}s must be a list.")
    out: dict[str, Any] = {}
    for entry in entries:
        name = entry.get("name") if isinstance(entry, dict) else None
        if not isinstance(name, str) or not name:
            raise ValueError(f"Each {what} needs a non-empty name.")
        if name in out:
            raise ValueError(f"Duplicate {what} name {name!r}.")
        out[name] = entry
    return out


def _column_descriptor(name: str, column: dict[str, Any]) -> _Column:
    declared = column.get("type")
    if declared is None:
        kind = "unknown"
    elif not isinstance(declared, str) or not declared:
        raise ValueError(f"Column {name!r} has an invalid type.")
    else:
        lower = declared.lower()
        if lower.startswith("number"):
            kind = "number"
        elif lower == "enum":
            kind = "string"
        elif lower.startswith("list("):
            kind = "list"
        elif lower in ("string", "boolean", "date", "datetime", "struct"):
            kind = lower
        else:
            raise ValueError(f"Column {name!r} has unsupported type {declared!r}.")
    fields: dict[str, _Column] = {}
    if kind == "struct":
        nested = _named_entries(column.get("fields"), "field")
        fields = {
            field_name: _column_descriptor(field_name, value)
            for field_name, value in nested.items()
        }
    return _Column(type=kind, fields=fields)


def _common_type(types: list[str]) -> str:
    types = [item for item in types if item != "any"]
    if not types:
        return "any"
    if "unknown" in types:
        return "unknown"
    unique = set(types)
    return types[0] if len(unique) == 1 else "any"


def _shape_max(*shapes: str) -> str:
    if not shapes:
        return "const"
    return max(shapes, key=lambda shape: _SHAPE_ORDER[shape])


def _append_unique(target: list[str], value: str) -> None:
    if value not in target:
        target.append(value)


def _is_date(value: Any) -> bool:
    if not isinstance(value, str) or not _DATE.match(value):
        return False
    try:
        parsed = date.fromisoformat(value)
    except ValueError:
        return False
    return parsed.isoformat() == value


def _as_datetime(value: Any) -> str | None:
    """Normalize an RFC 3339 string to data-dict's rendered datetime form."""
    if not isinstance(value, str):
        return None
    match = _DATETIME.match(value)
    if match is None:
        return None
    day, clock, fraction, offset = match.groups()
    offset = "+0000" if not offset or offset.lower() == "z" else offset.replace(":", "")
    try:
        parsed = datetime.strptime(f"{day}T{clock}{offset}", "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return None
    parsed = parsed.astimezone(UTC)
    return parsed.strftime("%Y-%m-%d %H:%M:%S") + _datetime_fraction(fraction)


def _datetime_fraction(fraction: str | None) -> str:
    """Render a fractional second at second, millisecond, or nanosecond width."""
    if not fraction:
        return ""
    digits = fraction[1:][:9]
    nanoseconds = int(digits + "0" * (9 - len(digits)))
    if nanoseconds == 0:
        return ""
    if nanoseconds % 1_000_000 == 0:
        return f".{nanoseconds // 1_000_000:03d}"
    if nanoseconds % 1_000 == 0:
        return f".{nanoseconds // 1_000:06d}"
    return f".{nanoseconds:09d}"

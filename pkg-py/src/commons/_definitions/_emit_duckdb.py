"""Lowering a type-checked expression to DuckDB SQL.

A port of data-dict's DuckDB emitter. Only DuckDB is ported, because commons
does not consume data-dict's R targets, and conformance against the data-dict
binary is the authority for what this must produce.

The emitter also collects notes: places where DuckDB's semantics differ from
data-dict's, which the model is told about rather than silently inheriting.
"""

from __future__ import annotations

import math
import re
from typing import Any

from ._export import Ir

__all__ = ["emit_duckdb"]

NAN_NOTE = (
    "DuckDB compares a NaN as equal to itself and greater than every number, "
    "where data-dict answers false; a row holding one passes here and is "
    "reported there."
)
MOD_NOTE = (
    "DuckDB yields null for an integer modulus by zero, where data-dict yields a NaN."
)
SUM_NOTE = (
    "DuckDB sums integers at 128 bits, so a total data-dict reports as an "
    "overflow (D09) may succeed."
)

# Precedence levels, loosest first. A child binding less tightly than its
# parent is parenthesised, and so is an equally tight child on the right,
# because these operators are left-associative.
_OR, _AND, _NOT, _COMPARE, _ADDITIVE, _MULTIPLICATIVE, _NEGATE, _ATOM = range(1, 9)

_SIMPLE_FUNCTIONS = {
    "length": "length",
    "lower": "lower",
    "upper": "upper",
    "trim": "trim",
    "starts_with": "starts_with",
    "ends_with": "ends_with",
    "abs": "abs",
    "floor": "floor",
    "ceil": "ceil",
    "round": "round",
    "is_finite": "isfinite",
    "is_infinite": "isinf",
    "is_nan": "isnan",
    "min": "min",
    "max": "max",
    "avg": "avg",
    "count": "count",
    "any": "bool_or",
    "all": "bool_and",
}

# Characters that must be escaped when a LIKE pattern becomes a regex.
_LIKE_ESCAPES = set("\\.+*?()|[]{}^$#-&~")
_LIKE_WILDCARD = re.compile(r"[%_]")


class _State:
    def __init__(self) -> None:
        self.notes: list[str] = []

    def note(self, note: str) -> None:
        self.notes.append(note)


def emit_duckdb(ir: Ir, selection: dict[str, Any] | None = None) -> dict[str, Any]:
    """Render a type-checked expression as DuckDB SQL, with its notes."""
    state = _State()
    if selection is None:
        code = _child(ir, 0, "free", state)
    else:
        # A `COLUMNS(...)` filter is one copy of the expression per selected
        # column, conjoined. Each copy binds at `AND` level, so anything
        # looser inside it is parenthesised.
        code = " AND ".join(
            _child(ir, _AND, "free", state, _identifier(column["path"]))
            for column in selection["columns"]
        )
    return {"code": code, "notes": sorted(set(state.notes))}


def _write(node: Ir, state: _State, selected: str | None = None) -> str:
    kind = node.kind
    attrs = node.attrs
    if kind == "number":
        return _number(node)
    if kind == "string":
        return _string(attrs["value"])
    if kind == "boolean":
        return "TRUE" if attrs["value"] else "FALSE"
    if kind == "null":
        return "NULL"
    if kind == "date":
        return f"DATE '{attrs['value']}'"
    if kind == "datetime":
        return f"TIMESTAMP '{attrs['value']}'"
    if kind == "now":
        return "current_timestamp"
    if kind == "column":
        return _identifier(attrs["path"])
    if kind == "selected":
        # Substituted per column by the caller.
        assert selected is not None
        return selected
    if kind == "negate":
        return "-" + _child(attrs["operand"], _NEGATE, "right", state, selected)
    if kind == "not":
        return "NOT " + _child(attrs["operand"], _NOT, "right", state, selected)
    if kind in ("and", "or"):
        level = _AND if kind == "and" else _OR
        return _infix(attrs["lhs"], attrs["rhs"], kind.upper(), level, state, selected)
    if kind == "arithmetic":
        op = attrs["op"]
        level = _ADDITIVE if op in ("+", "-") else _MULTIPLICATIVE
        return _infix(attrs["lhs"], attrs["rhs"], op, level, state, selected)
    if kind == "compare":
        if attrs["lhs"].type == "number" or attrs["rhs"].type == "number":
            state.note(NAN_NOTE)
        op = "<>" if attrs["op"] in ("!=", "<>") else attrs["op"]
        return _infix(attrs["lhs"], attrs["rhs"], op, _COMPARE, state, selected)
    if kind == "is_null":
        operand = _child(attrs["operand"], _COMPARE, "left", state, selected)
        return operand + (" IS NOT NULL" if attrs["negated"] else " IS NULL")
    if kind == "between":
        return _between(node, state, selected)
    if kind == "in":
        return _in(node, state, selected)
    if kind == "like":
        return _like(node, state, selected)
    if kind == "similar":
        operand = _child(attrs["operand"], 0, "free", state, selected)
        pattern = _child(attrs["pattern"], 0, "free", state, selected)
        prefix = "NOT " if attrs["negated"] else ""
        return f"{prefix}regexp_full_match({operand}, {pattern})"
    if kind == "interval":
        return _interval(node, state, selected)
    if kind == "case":
        return _case(node, state, selected)
    if kind == "function":
        return _function(node, state, selected)
    raise ValueError(f"No DuckDB translation for expression node {kind!r}.")


def _between(node: Ir, state: _State, selected: str | None) -> str:
    attrs = node.attrs
    if any(
        part.type == "number" for part in (attrs["operand"], attrs["lo"], attrs["hi"])
    ):
        state.note(NAN_NOTE)
    operand = _child(attrs["operand"], _COMPARE, "left", state, selected)
    lo = _child(attrs["lo"], _COMPARE, "right", state, selected)
    hi = _child(attrs["hi"], _COMPARE, "right", state, selected)
    op = " NOT BETWEEN " if attrs["negated"] else " BETWEEN "
    return f"{operand}{op}{lo} AND {hi}"


def _in(node: Ir, state: _State, selected: str | None) -> str:
    attrs = node.attrs
    if attrs["operand"].type == "number":
        state.note(NAN_NOTE)
    operand = _child(attrs["operand"], _COMPARE, "left", state, selected)
    items = ", ".join(
        _child(item, 0, "free", state, selected) for item in attrs["items"]
    )
    op = " NOT IN (" if attrs["negated"] else " IN ("
    return f"{operand}{op}{items})"


def _interval(node: Ir, state: _State, selected: str | None) -> str:
    attrs = node.attrs
    count = attrs["n"]
    unit = attrs["unit"]
    if count.kind == "number" and count.attrs.get("number_kind") == "integer":
        return f"INTERVAL '{count.attrs['value']} {unit}'"
    written = _child(count, 0, "free", state, selected)
    return f"({written} * INTERVAL '1 {unit}')"


def _case(node: Ir, state: _State, selected: str | None) -> str:
    branches = "".join(
        " WHEN {} THEN {}".format(
            _child(branch["condition"], 0, "free", state, selected),
            _child(branch["result"], 0, "free", state, selected),
        )
        for branch in node.attrs["whens"]
    )
    otherwise = node.attrs["otherwise"]
    tail = (
        f" ELSE {_child(otherwise, 0, 'free', state, selected)}"
        if otherwise is not None
        else ""
    )
    return f"CASE{branches}{tail} END"


def _function(node: Ir, state: _State, selected: str | None) -> str:
    name = node.attrs["name"]
    args = [_child(arg, 0, "free", state, selected) for arg in node.attrs["args"]]
    if name in _SIMPLE_FUNCTIONS:
        return f"{_SIMPLE_FUNCTIONS[name]}({', '.join(args)})"
    if name == "sum":
        state.note(SUM_NOTE)
        return f"sum({', '.join(args)})"
    if name == "row_count":
        return "count(*)"
    if name == "count_distinct":
        return f"count(DISTINCT {args[0]})"
    if name == "mod":
        # data-dict's modulus takes the sign of the divisor; DuckDB's takes the
        # sign of the dividend, so the divisor is added back before the second
        # mod. The divisor is written twice, once as an operand of `+`.
        state.note(MOD_NOTE)
        divisor = _child(node.attrs["args"][1], _ADDITIVE, "right", state, selected)
        return f"mod(mod({args[0]}, {args[1]}) + {divisor}, {args[1]})"
    raise ValueError(f"No DuckDB translation for function {name!r}.")


def _like(node: Ir, state: _State, selected: str | None) -> str:
    """Lower LIKE to the narrowest DuckDB form the pattern allows.

    An authored pattern is known at compile time, so a wildcard-free one is an
    equality and a single anchored wildcard is a prefix or suffix test. Only
    the general case needs a regex. A pattern that is itself an expression
    stays a LIKE, because none of that is knowable.
    """
    attrs = node.attrs
    negated = attrs["negated"]
    operand = _child(attrs["operand"], _COMPARE, "left", state, selected)
    pattern_node = attrs["pattern"]
    if pattern_node.kind != "string":
        pattern = _child(pattern_node, _COMPARE, "right", state, selected)
        op = " NOT LIKE " if negated else " LIKE "
        return f"{operand}{op}{pattern}"

    pattern = pattern_node.attrs["value"]
    count = len(_LIKE_WILDCARD.findall(pattern))
    if count == 0:
        op = " <> " if negated else " = "
        return f"{operand}{op}{_string(pattern)}"
    prefix = "NOT " if negated else ""
    bare = _child(attrs["operand"], 0, "free", state, selected)
    if count == 1 and pattern.endswith("%"):
        return f"{prefix}starts_with({bare}, {_string(pattern[:-1])})"
    if count == 1 and pattern.startswith("%"):
        return f"{prefix}ends_with({bare}, {_string(pattern[1:])})"
    return f"{prefix}regexp_full_match({bare}, {_string(_like_regex(pattern))})"


def _like_regex(pattern: str) -> str:
    out = []
    for char in pattern:
        if char == "%":
            out.append(".*")
        elif char == "_":
            out.append(".")
        elif char in _LIKE_ESCAPES:
            out.append("\\" + char)
        else:
            out.append(char)
    return "^" + "".join(out) + "$"


def _infix(
    lhs: Ir, rhs: Ir, op: str, level: int, state: _State, selected: str | None
) -> str:
    left = _child(lhs, level, "left", state, selected)
    right = _child(rhs, level, "right", state, selected)
    return f"{left} {op} {right}"


def _child(
    node: Ir, parent: int, side: str, state: _State, selected: str | None = None
) -> str:
    own = _precedence(node)
    code = _write(node, state, selected)
    if own < parent or (own == parent and side == "right"):
        return f"({code})"
    return code


def _precedence(node: Ir) -> int:
    kind = node.kind
    if kind == "or":
        return _OR
    if kind == "and":
        return _AND
    if kind == "not":
        return _NOT
    if kind in ("compare", "is_null", "between", "in", "like"):
        return _COMPARE
    if kind == "arithmetic":
        return _ADDITIVE if node.attrs["op"] in ("+", "-") else _MULTIPLICATIVE
    if kind == "negate":
        return _NEGATE
    return _ATOM


def _identifier(path: Any) -> str:
    segments = path if isinstance(path, list) else [path]
    return ".".join('"{}"'.format(str(part).replace('"', '""')) for part in segments)


def _string(value: str) -> str:
    escaped = value.replace("'", "''")
    return f"'{escaped}'"


def _number(node: Ir) -> str:
    value = node.attrs["value"]
    if node.attrs.get("number_kind") == "integer":
        return str(value)
    if math.isnan(value):
        return "CAST('NaN' AS DOUBLE)"
    if math.isinf(value):
        sign = "-" if value < 0 else ""
        return f"CAST('{sign}Infinity' AS DOUBLE)"
    text = _float(value)
    return text if re.search(r"[.eE]", text) else text + ".0"


def _float(value: float) -> str:
    """The shortest fixed-point text that reads back as this exact double.

    Not `repr`, which switches to exponent notation for large and small
    magnitudes and would emit `1e+20` where data-dict emits the digits. The
    width is widened a significant figure at a time until the text round-trips.
    """
    exponent = 0 if value == 0 else math.floor(math.log10(abs(value)))
    for significant in range(1, 18):
        places = max(0, significant - 1 - exponent)
        candidate = f"{value:.{places}f}"
        try:
            if float(candidate) == value:
                return candidate
        except ValueError:  # pragma: no cover - a finite float always parses
            continue
    return f"{value:.17f}"

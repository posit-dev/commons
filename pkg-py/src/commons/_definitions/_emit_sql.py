"""Lowering a type-checked expression to Snowflake or Databricks SQL.

The two share precedence and most expression syntax, so they are one writer
parameterised by dialect. Their semantic differences are concentrated in the
operations that need target-aware lowering: identifiers, datetimes, division,
modulus, non-finite numbers, and regular expressions.

Unlike DuckDB, these targets have no upstream authority. The pinned data-dict
binary emits DuckDB and R targets only, so nothing external says what correct
output is. Agreement between the two commons implementations is pinned in
`tests/shared/definition-warehouse-sql.json`; see kata g0ax for the upstream
ask that would remove the need for this module entirely.
"""

from __future__ import annotations

import math
import re
from typing import Any

from ._emit_duckdb import (
    _ADDITIVE,
    _AND,
    _COMPARE,
    _MULTIPLICATIVE,
    _NEGATE,
    _NOT,
    _OR,
    _float,
    _like_regex,
)
from ._export import Ir

__all__ = ["Unsupported", "emit_sql"]

DIALECTS = ("snowflake", "databricks")

_MICROSECONDS = {
    "seconds": "1000000",
    "minutes": "60000000",
    "hours": "3600000000",
    "days": "86400000000",
    "weeks": "604800000000",
}

_SIMPLE_FUNCTIONS = {
    "length": "length",
    "lower": "lower",
    "upper": "upper",
    "trim": "trim",
    "abs": "abs",
    "floor": "floor",
    "ceil": "ceil",
    "min": "min",
    "max": "max",
    "avg": "avg",
    "count": "count",
}

_NAN_NOTE = {
    dialect: (
        f"{dialect.capitalize()} orders a NaN as equal to itself and greater "
        f"than every number, where data-dict uses IEEE comparisons."
    )
    for dialect in DIALECTS
}
_DIVISION_NOTE = {
    dialect: (
        f"Guarded division cannot distinguish a negative zero divisor in "
        f"{dialect.capitalize()}; its result has positive-zero semantics."
    )
    for dialect in DIALECTS
}
_TRIM_NOTE = {
    "snowflake": (
        "Snowflake TRIM removes spaces by default, where data-dict removes "
        "Unicode whitespace."
    ),
    "databricks": (
        "Databricks trim removes spaces by default, where data-dict removes "
        "Unicode whitespace."
    ),
}
_LIKE_NOTE = {
    "snowflake": (
        "Snowflake LIKE wildcards match newline characters, where data-dict's "
        "wildcards do not."
    ),
    "databricks": (
        "A dynamic Databricks LIKE pattern treats backslash as an escape, "
        "where data-dict treats it literally."
    ),
}
_REGEX_NOTE = {
    "snowflake": (
        "Snowflake evaluates POSIX regular expressions, which can differ from "
        "data-dict's Rust regex engine."
    ),
    "databricks": (
        "Databricks evaluates Java regular expressions, which can differ from "
        "data-dict's Rust regex engine."
    ),
}
_SUM_NOTE = {
    dialect: (
        f"{dialect.capitalize()} numeric precision and overflow can differ "
        f"from data-dict's 64-bit integer and floating-point accumulation."
    )
    for dialect in DIALECTS
}


class Unsupported(Exception):
    """A construct this dialect cannot express.

    Raised while walking, caught at the top, and returned as an `error` on the
    translation rather than propagating. A target that cannot express one
    definition should not stop the others being emitted.
    """


class _State:
    def __init__(self, dialect: str) -> None:
        self.dialect = dialect
        self.notes: list[str] = []

    def note(self, note: str) -> None:
        self.notes.append(note)


def emit_sql(
    ir: Ir, dialect: str, selection: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Render a type-checked expression for `dialect`, with its notes."""
    if dialect not in DIALECTS:
        raise ValueError(f"Unknown SQL dialect {dialect!r}.")
    state = _State(dialect)
    try:
        if selection is None:
            code = _child(ir, 0, "free", state)
        else:
            code = " AND ".join(
                _child(ir, _AND, "free", state, _identifier(column["path"], dialect))
                for column in selection["columns"]
            )
    except Unsupported as unsupported:
        return {
            "code": None,
            "error": str(unsupported),
            "notes": sorted(set(state.notes)),
        }
    return {"code": code, "error": None, "notes": sorted(set(state.notes))}


def _unsupported(dialect: str, what: str, why: str) -> Any:
    raise Unsupported(f"{what} is not supported for {dialect}: {why}.")


def _write(node: Ir, state: _State, selected: str | None = None) -> str:
    kind = node.kind
    attrs = node.attrs
    dialect = state.dialect
    if kind == "number":
        return _number(node, dialect)
    if kind == "string":
        return _string(attrs["value"])
    if kind == "boolean":
        return "TRUE" if attrs["value"] else "FALSE"
    if kind == "null":
        return "NULL"
    if kind == "date":
        return f"DATE '{attrs['value']}'"
    if kind == "datetime":
        return _datetime(attrs["value"], dialect)
    if kind == "now":
        return "CURRENT_TIMESTAMP()"
    if kind == "column":
        return _identifier(attrs["path"], dialect)
    if kind == "selected":
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
        shifted = _temporal_shift(node, state, selected)
        if shifted is not None:
            return shifted
        if attrs["op"] == "/":
            return _divide(node, state, selected)
        level = _ADDITIVE if attrs["op"] in ("+", "-") else _MULTIPLICATIVE
        return _infix(attrs["lhs"], attrs["rhs"], attrs["op"], level, state, selected)
    if kind == "compare":
        if attrs["lhs"].type == "number" or attrs["rhs"].type == "number":
            state.note(_NAN_NOTE[dialect])
        op = "<>" if attrs["op"] in ("!=", "<>") else attrs["op"]
        return _infix(attrs["lhs"], attrs["rhs"], op, _COMPARE, state, selected)
    if kind == "is_null":
        operand = _child(attrs["operand"], _COMPARE, "left", state, selected)
        return operand + (" IS NOT NULL" if attrs["negated"] else " IS NULL")
    if kind == "between":
        if any(
            part.type == "number"
            for part in (attrs["operand"], attrs["lo"], attrs["hi"])
        ):
            state.note(_NAN_NOTE[dialect])
        operand = _child(attrs["operand"], _COMPARE, "left", state, selected)
        lo = _child(attrs["lo"], _COMPARE, "right", state, selected)
        hi = _child(attrs["hi"], _COMPARE, "right", state, selected)
        op = " NOT BETWEEN " if attrs["negated"] else " BETWEEN "
        return f"{operand}{op}{lo} AND {hi}"
    if kind == "in":
        if attrs["operand"].type == "number":
            state.note(_NAN_NOTE[dialect])
        operand = _child(attrs["operand"], _COMPARE, "left", state, selected)
        items = ", ".join(
            _child(item, 0, "free", state, selected) for item in attrs["items"]
        )
        op = " NOT IN (" if attrs["negated"] else " IN ("
        return f"{operand}{op}{items})"
    if kind == "like":
        return _like(node, state, selected)
    if kind == "similar":
        return _similar(node, state, selected)
    if kind == "interval":
        _unsupported(
            dialect,
            "a standalone interval",
            "intervals are supported only when shifting a date or datetime",
        )
    if kind == "case":
        return _case(node, state, selected)
    if kind == "function":
        return _function(node, state, selected)
    raise ValueError(f"No SQL translation for expression node {kind!r}.")


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
    dialect = state.dialect
    name = node.attrs["name"]
    arg_nodes = node.attrs["args"]
    args = [_child(arg, 0, "free", state, selected) for arg in arg_nodes]
    if name in _SIMPLE_FUNCTIONS:
        if name == "trim":
            state.note(_TRIM_NOTE[dialect])
        return f"{_SIMPLE_FUNCTIONS[name]}({', '.join(args)})"
    if name in ("starts_with", "ends_with"):
        return f"{_affix_function(name, dialect)}({', '.join(args)})"
    if name == "round":
        if len(arg_nodes) == 2:
            if dialect == "databricks" and arg_nodes[1].shape != "const":
                _unsupported(
                    dialect,
                    "a dynamic ROUND() scale",
                    "Databricks requires the scale to be an integer constant "
                    "expression",
                )
            args[1] = (
                f"TRUNC({args[1]})"
                if dialect == "snowflake"
                else f"CAST({args[1]} AS INT)"
            )
        return f"round({', '.join(args)})"
    if name == "mod":
        return _mod(node, args, state, selected)
    if name in ("is_finite", "is_infinite", "is_nan"):
        return _non_finite(name, args[0], dialect)
    if name == "sum":
        state.note(_SUM_NOTE[dialect])
        return f"sum({args[0]})"
    if name == "row_count":
        return "count(*)"
    if name == "count_distinct":
        return f"count(DISTINCT {args[0]})"
    if name in ("any", "all"):
        if dialect == "snowflake":
            fn = "BOOLOR_AGG" if name == "any" else "BOOLAND_AGG"
        else:
            fn = "bool_or" if name == "any" else "bool_and"
        return f"{fn}({args[0]})"
    raise ValueError(f"No SQL translation for function {name!r}.")


def _affix_function(name: str, dialect: str) -> str:
    if dialect == "snowflake":
        return "STARTSWITH" if name == "starts_with" else "ENDSWITH"
    return "startswith" if name == "starts_with" else "endswith"


def _mod(node: Ir, args: list[str], state: _State, selected: str | None) -> str:
    """Modulus, guarded so a zero divisor yields NaN rather than null.

    data-dict yields a NaN; both warehouses yield null. The divisor is written
    twice because the sign correction adds it back.
    """
    divisor = _child(node.attrs["args"][1], _ADDITIVE, "right", state, selected)
    nan = _non_finite_literal("nan", state.dialect)
    value = f"MOD(MOD({args[0]}, {args[1]}) + {divisor}, {args[1]})"
    return f"CASE WHEN {divisor} = 0 THEN {nan} ELSE {value} END"


def _divide(node: Ir, state: _State, selected: str | None) -> str:
    """Division, guarded so a zero divisor follows IEEE rather than yielding null.

    data-dict divides by zero to an infinity or a NaN. Both warehouses return
    null, so the cases are written out.
    """
    dialect = state.dialect
    numerator = _child(node.attrs["lhs"], 0, "free", state, selected)
    divisor = _child(node.attrs["rhs"], 0, "free", state, selected)
    nan = _non_finite_literal("nan", dialect)
    infinity = _non_finite_literal("inf", dialect)
    negative_infinity = _non_finite_literal("-inf", dialect)
    is_nan = _non_finite("is_nan", numerator, dialect)
    state.note(_DIVISION_NOTE[dialect])
    return (
        f"CASE WHEN {divisor} = 0 THEN CASE "
        f"WHEN {numerator} IS NULL THEN NULL "
        f"WHEN {is_nan} OR {numerator} = 0 THEN {nan} "
        f"WHEN {numerator} < 0 THEN {negative_infinity} ELSE {infinity} END "
        f"ELSE {numerator} / {divisor} END"
    )


def _non_finite(name: str, arg: str, dialect: str) -> str:
    """Spell out a finiteness test, which neither warehouse has as a builtin."""
    nan = _non_finite_literal("nan", dialect)
    infinity = _non_finite_literal("inf", dialect)
    negative_infinity = _non_finite_literal("-inf", dialect)
    if dialect == "snowflake":
        if name == "is_nan":
            predicate = f"{arg} = {nan}"
        elif name == "is_infinite":
            predicate = f"{arg} IN ({infinity}, {negative_infinity})"
        else:
            predicate = (
                f"{arg} <> {nan} AND {arg} NOT IN ({infinity}, {negative_infinity})"
            )
        return f"({predicate})"
    if name == "is_nan":
        predicate = f"isnan({arg})"
    elif name == "is_infinite":
        predicate = f"{arg} IN ({infinity}, {negative_infinity})"
    else:
        predicate = (
            f"NOT isnan({arg}) AND {arg} NOT IN ({infinity}, {negative_infinity})"
        )
    return f"(CASE WHEN {arg} IS NULL THEN NULL ELSE {predicate} END)"


def _like(node: Ir, state: _State, selected: str | None) -> str:
    dialect = state.dialect
    attrs = node.attrs
    negated = attrs["negated"]
    operand = _child(attrs["operand"], _COMPARE, "left", state, selected)
    pattern_node = attrs["pattern"]
    if pattern_node.kind != "string":
        state.note(_LIKE_NOTE[dialect])
        pattern = _child(pattern_node, _COMPARE, "right", state, selected)
        op = " NOT LIKE " if negated else " LIKE "
        return f"{operand}{op}{pattern}"

    pattern = pattern_node.attrs["value"]
    count = len(re.findall(r"[%_]", pattern))
    if count == 0:
        op = " <> " if negated else " = "
        return f"{operand}{op}{_string(pattern)}"
    prefix = "NOT " if negated else ""
    bare = _child(attrs["operand"], 0, "free", state, selected)
    if count == 1 and pattern.endswith("%"):
        fn = _affix_function("starts_with", dialect)
        return f"{prefix}{fn}({bare}, {_string(pattern[:-1])})"
    if count == 1 and pattern.startswith("%"):
        fn = _affix_function("ends_with", dialect)
        return f"{prefix}{fn}({bare}, {_string(pattern[1:])})"
    fn = "REGEXP_LIKE" if dialect == "snowflake" else "regexp_like"
    return f"{prefix}{fn}({bare}, {_string(_like_regex(pattern))})"


def _similar(node: Ir, state: _State, selected: str | None) -> str:
    dialect = state.dialect
    state.note(_REGEX_NOTE[dialect])
    attrs = node.attrs
    operand = _child(attrs["operand"], 0, "free", state, selected)
    pattern = _child(attrs["pattern"], 0, "free", state, selected)
    if dialect == "databricks":
        # Databricks matches partially; data-dict's SIMILAR TO is anchored.
        pattern = f"concat('^(?:', {pattern}, ')$')"
    prefix = "NOT " if attrs["negated"] else ""
    fn = "REGEXP_LIKE" if dialect == "snowflake" else "regexp_like"
    return f"{prefix}{fn}({operand}, {pattern})"


def _temporal_shift(node: Ir, state: _State, selected: str | None) -> str | None:
    """A date or datetime plus or minus an interval, as a microsecond add.

    Neither warehouse takes an interval literal the way DuckDB does, so the
    interval becomes a count of microseconds.
    """
    attrs = node.attrs
    lhs_interval = attrs["lhs"].type == "interval"
    rhs_interval = attrs["rhs"].type == "interval"
    if not lhs_interval and not rhs_interval:
        return None
    dialect = state.dialect
    if lhs_interval and attrs["op"] == "-":
        _unsupported(
            dialect,
            "an interval minus a temporal value",
            "data-dict does not define an executable temporal shift for that order",
        )
    interval = attrs["lhs"] if lhs_interval else attrs["rhs"]
    base = attrs["rhs"] if lhs_interval else attrs["lhs"]
    amount = _child(interval.attrs["n"], 0, "free", state, selected)
    amount = f"({amount}) * {_MICROSECONDS[interval.attrs['unit']]}"
    if attrs["op"] == "-" and rhs_interval:
        amount = f"-({amount})"
    value = _child(base, 0, "free", state, selected)
    fn = "DATEADD" if dialect == "snowflake" else "timestampadd"
    return f"{fn}(MICROSECOND, {amount}, {value})"


def _infix(
    lhs: Ir, rhs: Ir, op: str, level: int, state: _State, selected: str | None
) -> str:
    left = _child(lhs, level, "left", state, selected)
    right = _child(rhs, level, "right", state, selected)
    return f"{left} {op} {right}"


def _child(
    node: Ir, parent: int, side: str, state: _State, selected: str | None = None
) -> str:
    from ._emit_duckdb import _precedence

    own = _precedence(node)
    code = _write(node, state, selected)
    if own < parent or (own == parent and side == "right"):
        return f"({code})"
    return code


def _identifier(path: Any, dialect: str) -> str:
    segments = list(path) if isinstance(path, list) else [path]
    if dialect == "snowflake" and len(segments) > 1:
        # Snowflake reads a struct field with GET() rather than a dotted path.
        out = _quote_identifier(segments[0], dialect)
        for field in segments[1:]:
            out = f"GET({out}, {_string(str(field))})"
        return out
    return ".".join(_quote_identifier(part, dialect) for part in segments)


def _quote_identifier(name: Any, dialect: str) -> str:
    quote = "`" if dialect == "databricks" else '"'
    escaped = str(name).replace(quote, quote * 2)
    return f"{quote}{escaped}{quote}"


def _string(value: str) -> str:
    # Both warehouses treat a backslash as an escape inside a string literal,
    # where data-dict treats it literally.
    return "'" + value.replace("'", "''").replace("\\", "\\\\") + "'"


def _number(node: Ir, dialect: str) -> str:
    value = node.attrs["value"]
    if node.attrs.get("number_kind") == "integer":
        return str(value)
    if math.isnan(value):
        return _non_finite_literal("nan", dialect)
    if math.isinf(value):
        return _non_finite_literal("-inf" if value < 0 else "inf", dialect)
    text = _float(value)
    return text if re.search(r"[.eE]", text) else text + ".0"


def _non_finite_literal(value: str, dialect: str) -> str:
    if value == "nan":
        literal = "NaN"
    elif value == "inf":
        literal = "inf" if dialect == "snowflake" else "Infinity"
    else:
        literal = "-inf" if dialect == "snowflake" else "-Infinity"
    return f"CAST('{literal}' AS DOUBLE)"


_DATETIME = re.compile(
    r"^([0-9]{4})-([0-9]{2})-([0-9]{2}) "
    r"([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?$"
)


def _datetime(value: str, dialect: str) -> str:
    if dialect == "snowflake":
        return f"TO_TIMESTAMP_TZ('{value} +00:00')"
    match = _DATETIME.match(value)
    if match is None:  # pragma: no cover - the export normalizes this shape
        raise ValueError(f"Unrecognised datetime literal {value!r}.")
    year, month, day, hour, minute, second, fraction = match.groups()
    fraction = fraction or ""
    digits = fraction[1:]
    if len(digits) > 6 and int(digits[6:]) != 0:
        _unsupported(
            dialect,
            "a nanosecond datetime literal",
            "Databricks timestamps have microsecond precision",
        )
    seconds = f"{int(second)}{fraction}"
    return (
        f"make_timestamp({int(year)}, {int(month)}, {int(day)}, "
        f"{int(hour)}, {int(minute)}, {seconds}, 'UTC')"
    )

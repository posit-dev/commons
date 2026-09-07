"""A column-by-column summary of the rows a table sample returned.

`describe_table` shows this instead of the sample rows themselves: five rows
of values tell a model less about a column than its range, its missing count,
and the values it actually takes.

The shape is the one `ellmer::df_schema()` produces for the R agent, and it is
a cross-language contract: which facts each kind of column reports, the order
they appear in, the punctuation between them, and the header line are pinned
by `tests/shared/sample-summary.json`.

The type token in front of those facts is deliberately not shared. R names R's
types because it is describing an R vector; this names Python's, because a row
here is a mapping of Python values and calling an `int` an `integer` would
describe a vector nobody has:

    R            Python     notes
    integer      int
    numeric      float      also Decimal; `number` for a mix of numeric types
    character    str
    logical      bool
    date         date       datetime.date
    date-time    datetime   datetime.datetime
    list column  list       also dict and bytes: no summary worth giving
    (its type)   unknown    every value in the sample was null
    (n/a)        mixed      the sample holds more than one kind of value

A driver returns one type per column, so `number` and `mixed` are for the rows
a caller builds by hand rather than for anything a query produces.
"""

from __future__ import annotations

import datetime
import math
from collections.abc import Sequence
from decimal import Decimal
from typing import Any

__all__ = ["SAMPLE_SUMMARY_HEADING", "sample_summary"]

SAMPLE_SUMMARY_HEADING = "Sample summary:"

# Past this many distinct values, or this much text, listing them costs more
# context than it tells the model.
MAX_LISTED_VALUES = 10
MAX_LISTED_CHARS = 200

# Significant digits in a reported range. Four keeps a range readable without
# implying more precision than a five-row sample has.
RANGE_DIGITS = 4

_NUMERIC = (int, float, Decimal)

# The C escapes, and the two characters that would otherwise end or continue
# the quoting. Anything else printable is left as authored.
_ESCAPES = {
    "\\": "\\\\",
    '"': '\\"',
    "\a": "\\a",
    "\b": "\\b",
    "\f": "\\f",
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
    "\v": "\\v",
}


def sample_summary(
    rows: list[dict[str, Any]], columns: Sequence[str] | None = None
) -> str:
    """Describe each column of `rows`, one line apiece.

    `columns` fixes the columns and their order, so a table whose sample came
    back empty is still described by name. Without it the columns are the
    union of the keys the rows carry, in the order they first appear.
    """
    names = (
        list(columns)
        if columns is not None
        else list(dict.fromkeys(key for row in rows for key in row))
    )
    lines = [f"A data frame with {len(rows)} rows and {len(names)} columns:"]
    lines += [
        f"* {name}: {_column_summary([row.get(name) for row in rows])}"
        for name in names
    ]
    return "\n".join(lines)


def _column_summary(values: list[Any]) -> str:
    present = [value for value in values if not _is_missing(value)]
    missing = f"{len(values) - len(present)} NAs"
    token, facts = _token_and_facts(present, missing)
    if not facts:
        return token
    return f"{token} with {_flatten(facts)}"


def _is_missing(value: Any) -> bool:
    """Whether a value is absent, counting a NaN as absent.

    R counts a NaN as NA and leaves it out of a range, and a sample comes back
    in whatever order the query returned, so keeping one would make a column's
    range depend on which row happened to come first.
    """
    return value is None or _is_nan(value)


def _is_nan(value: Any) -> bool:
    # Asked of the Decimal rather than of math, which refuses to convert a
    # signalling NaN to a float and raises instead of answering.
    if isinstance(value, Decimal):
        return value.is_nan()
    return isinstance(value, float) and math.isnan(value)


def _token_and_facts(present: list[Any], missing: str) -> tuple[str, list[str]]:
    if not present:
        return "unknown", [missing]
    if all(isinstance(value, bool) for value in present):
        trues = sum(1 for value in present if value)
        return "bool", [
            f"{trues} TRUEs",
            f"{len(present) - trues} FALSEs",
            missing,
        ]
    if all(
        isinstance(value, _NUMERIC) and not isinstance(value, bool) for value in present
    ):
        # Not converted to float first: a Decimal and an integer wider than a
        # float's mantissa both report their own value exactly.
        return _one_name(present, "number"), [
            _range(present, _format_number),
            missing,
        ]
    if all(isinstance(value, str) for value in present):
        return "str", [missing, _unique(present)]
    if all(isinstance(value, datetime.datetime) for value in present) and _comparable(
        present
    ):
        zone = _timezone(present)
        facts = [_range(present, _format_datetime), missing]
        return "datetime", ([zone, *facts] if zone else facts)
    if all(
        isinstance(value, datetime.date) and not isinstance(value, datetime.datetime)
        for value in present
    ):
        return "date", [_range(present, datetime.date.isoformat), missing]
    # A value with no summary worth giving: its type is all the model gets.
    if all(
        isinstance(value, (list, tuple, dict, bytes, bytearray)) for value in present
    ):
        return _one_name(present, "list"), []
    return "mixed", [missing]


def _comparable(present: list[datetime.datetime]) -> bool:
    """Whether these timestamps can be ordered against each other.

    Python refuses to compare an aware timestamp with a naive one, and no
    driver returns both from one column, so a column holding both is reported
    as mixed rather than raising out of a tool.
    """
    return len({value.tzinfo is None for value in present}) == 1


def _one_name(present: list[Any], fallback: str) -> str:
    """The values' shared type name, or `fallback` when they differ."""
    names = {type(value).__name__ for value in present}
    return names.pop() if len(names) == 1 else fallback


def _timezone(present: list[datetime.datetime]) -> str | None:
    names = {value.tzname() for value in present}
    if len(names) != 1:
        return None
    name = names.pop()
    return f"timezone {name}" if name else None


def _range(present: list[Any], render: Any) -> str:
    return f"range [{render(min(present))}, {render(max(present))}]"


def _format_datetime(value: datetime.datetime) -> str:
    # Seconds, not microseconds: a sub-second tail is noise in a range and R's
    # own POSIXct formatting drops it too.
    return value.strftime("%Y-%m-%d %H:%M:%S")


def _unique(present: list[str]) -> str:
    unique = list(dict.fromkeys(present))
    described = f"{len(unique)} unique values"
    if not unique or len(unique) > MAX_LISTED_VALUES:
        return described
    if sum(len(value) for value in unique) >= MAX_LISTED_CHARS:
        return described
    listed = ", ".join(_quote(value) for value in unique)
    return f"{described} ({listed})"


def _quote(value: str) -> str:
    out = []
    for character in value:
        escape = _ESCAPES.get(character)
        if escape is not None:
            out.append(escape)
        elif character < " " or character == "\x7f":
            out.append(f"\\x{ord(character):02x}")
        else:
            out.append(character)
    return '"' + "".join(out) + '"'


def _flatten(facts: list[str]) -> str:
    """Join the facts the way the shared contract spells a list.

    One fact stands alone, two are joined by ", and ", and more take a comma
    between each and ", and " before the last.
    """
    if len(facts) == 1:
        return facts[0]
    return ", ".join([*facts[:-2], f"{facts[-2]}, and {facts[-1]}"])


def _format_number(value: float | Decimal) -> str:
    """Render one end of a range.

    A whole number is written out in full, however many digits it has, which
    is what keeps a `2147483647` id from being reported as `2.147e+09`.
    """
    if isinstance(value, int):
        return str(value)
    return _format_signif(value)


def _format_signif(value: float | Decimal, digits: int = RANGE_DIGITS) -> str:
    """Render a number to `digits` significant digits, fixed or scientific.

    Fixed notation unless scientific is strictly shorter, which is what keeps
    `1234567` from becoming `1.235e+06` while `1e+10` does not become
    `10000000000`. Only the decimal places are decided by `digits`: the digits
    left of the point are never dropped.
    """
    if _is_nan(value):
        return "NaN"
    if math.isinf(value):
        return "Inf" if value > 0 else "-Inf"
    if value == 0:
        return "0"
    mantissa, _, exponent = f"{value:.{digits - 1}e}".partition("e")
    significant = len(mantissa.replace("-", "").replace(".", "").rstrip("0")) or 1
    decimals = max(0, significant - 1 - int(exponent))
    fixed = f"{value:.{decimals}f}"
    scientific = _padded_exponent(f"{value:.{significant - 1}e}")
    return fixed if len(fixed) <= len(scientific) else scientific


def _padded_exponent(text: str) -> str:
    """Two exponent digits, which is what a float already formats to.

    Decimal does not pad, so without this the same magnitude reads `1.234e-5`
    from a DECIMAL column and `1.234e-05` from a DOUBLE one.
    """
    mantissa, marker, exponent = text.partition("e")
    if not marker:
        return text
    return f"{mantissa}e{exponent[0]}{exponent[1:].zfill(2)}"

"""Query results as the model reads them.

A source hands back rows as a list of mappings, and every tool that returns
data renders them the same way, so the rendering lives here rather than in
each tool body.

The vocabulary is the one `pkg-r/R/utils.R` uses — a null is `NA`, a
boolean is `TRUE` or `FALSE`, and a float keeps seven significant digits —
so the model meets one spelling per idea across every tool and both
packages. Three choices deliberately differ from R's
`knitr::kable` rather than matching it: an empty result says "No rows."
because a list of no mappings carries no column names to head a table with,
a line break inside a value folds to a space because kable passes it through
and breaks its own table, and a pipe escapes as `\\|` because the model
reads that as readily as kable's `&#124;`.
"""

from __future__ import annotations

import importlib
import math
import re
from decimal import Decimal
from typing import Any

__all__ = [
    "MAX_MARKDOWN_ROWS",
    "frame_rows",
    "render_value",
    "rows_frame",
    "rows_to_markdown",
]

# Enough rows to reason over, few enough that one query cannot crowd the
# conversation out of its context window. The handle store keeps the rest.
MAX_MARKDOWN_ROWS = 50


def rows_to_markdown(
    rows: list[dict[str, Any]], max_rows: int = MAX_MARKDOWN_ROWS
) -> str:
    """Render rows as a pipe table, capped and with the cap reported."""
    if not rows:
        return "No rows."
    # Union rather than the first row's keys: a driver may omit a null column.
    columns = list(dict.fromkeys(key for row in rows for key in row))
    lines = [
        "| " + " | ".join(_cell(column) for column in columns) + " |",
        "|" + "|".join("---" for _ in columns) + "|",
    ]
    lines.extend(
        "| " + " | ".join(_cell(row.get(column)) for column in columns) + " |"
        for row in rows[:max_rows]
    )
    if len(rows) > max_rows:
        lines.extend(["", f"{len(rows) - max_rows} more rows not shown"])
    return "\n".join(lines)


_LINE_BREAK = re.compile(r"\r\n|[\r\n]")

# Significant digits a rendered number keeps, matching R's format() default:
# enough to read, few enough that a float's representation noise (0.1 + 0.2)
# never reaches the model. Whole numbers are written out in full either way.
VALUE_DIGITS = 7


def render_value(value: Any) -> str:
    """One value as the model reads it, in the shared vocabulary."""
    if value is None:
        return "NA"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (float, Decimal)):
        return _format_signif(value, VALUE_DIGITS)
    return str(value)


def _cell(value: Any) -> str:
    """One cell, with everything that would break the table out of it.

    A column name goes through this too: a query names its own aliases, so a
    header is no safer than a value.
    """
    return _LINE_BREAK.sub(" ", render_value(value)).replace("|", "\\|")


def frame_rows(frame: Any) -> list[dict[str, Any]] | None:
    """A frame's rows as mappings, or None when it cannot offer them.

    Duck-typed for the same reason `_frames` is: pandas and polars are both
    optional wherever a frame is accepted.
    """
    if hasattr(frame, "to_dicts"):
        rows = frame.to_dicts()
    elif hasattr(frame, "to_dict"):
        rows = frame.to_dict(orient="records")
    else:
        return None
    return rows if isinstance(rows, list) else None


def rows_frame(rows: list[dict[str, Any]]) -> Any:
    """The rows as a data frame, or unchanged when no frame library can hold them.

    A frame crosses into the Python session with its column types, dates
    included, where a list of mappings holding a date would arrive only as
    text. pandas is tried first, since it is what code most often expects,
    then polars, then a pyarrow Table, which commons always has.
    """
    for library in ("pandas", "polars"):
        try:
            module = importlib.import_module(library)
        except ImportError:
            continue
        try:
            return module.DataFrame(rows)
        except Exception:  # noqa: BLE001 - a column the library refuses keeps the rows
            return rows
    pyarrow = importlib.import_module("pyarrow")
    try:
        return pyarrow.Table.from_pylist(rows)
    except (pyarrow.ArrowInvalid, pyarrow.ArrowTypeError):
        return rows


def _format_signif(value: float | Decimal, digits: int) -> str:
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


def _is_nan(value: Any) -> bool:
    # Asked of the Decimal rather than of math, which refuses to convert a
    # signalling NaN to a float and raises instead of answering.
    if isinstance(value, Decimal):
        return value.is_nan()
    return isinstance(value, float) and math.isnan(value)

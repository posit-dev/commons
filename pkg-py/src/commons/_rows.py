"""Query results as the model reads them.

A source hands back rows as a list of mappings, and every tool that returns
data renders them the same way, so the rendering lives here rather than in
each tool body.

The vocabulary is the one the sample summary and `pkg-r/R/utils.R` use — a
null is `NA`, a boolean is `TRUE` or `FALSE`, and a float keeps seven
significant digits — so the model meets one spelling per idea across every
tool and both packages. Three choices deliberately differ from R's
`knitr::kable` rather than matching it: an empty result says "No rows."
because a list of no mappings carries no column names to head a table with,
a line break inside a value folds to a space because kable passes it through
and breaks its own table, and a pipe escapes as `\\|` because the model
reads that as readily as kable's `&#124;`.
"""

from __future__ import annotations

import re
from decimal import Decimal
from typing import Any

from ._sample_summary import _format_signif

__all__ = ["MAX_MARKDOWN_ROWS", "frame_rows", "render_value", "rows_to_markdown"]

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

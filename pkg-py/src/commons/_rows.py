"""Query results as the model reads them.

A source hands back rows as a list of mappings, and every tool that returns
data renders them the same way, so the rendering lives here rather than in
each tool body.
"""

from __future__ import annotations

import re
from typing import Any

__all__ = ["MAX_MARKDOWN_ROWS", "frame_rows", "rows_to_markdown"]

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


def _cell(value: Any) -> str:
    """One cell, with everything that would break the table out of it.

    A column name goes through this too: a query names its own aliases, so a
    header is no safer than a value.
    """
    if value is None:
        return ""
    return _LINE_BREAK.sub(" ", str(value)).replace("|", "\\|")


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

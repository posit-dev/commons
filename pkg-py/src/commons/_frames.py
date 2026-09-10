"""Recognizing and describing a data frame, whichever library it came from.

pandas and polars are both optional at every boundary that accepts a frame,
so neither is imported here: a frame is recognized and read through what it
offers rather than through its class.
"""

from __future__ import annotations

import json
from typing import Any

__all__ = ["describe_frame", "is_frame"]


# len() and [] are what describing a frame needs, so a value that merely has
# columns — a database table, say — is not one.
def is_frame(value: Any) -> bool:
    return (
        hasattr(value, "__dataframe__") or hasattr(value, "columns")
    ) and hasattr(value, "__len__") and hasattr(value, "__getitem__")


# The handle store's own description of a frame, for whichever frame library
# the result came from. Not the one `describe_table` shows: that summary is a
# cross-language contract and lives in `_sample_summary`, over rows rather
# than over a frame.
MAX_SUMMARY_COLUMNS = 50


def describe_frame(frame: Any, max_columns: int = MAX_SUMMARY_COLUMNS) -> str:
    """A column-by-column description, so the model can write code against it."""
    names = list(frame.columns)
    shape = f"{_count(len(frame), 'row')} and {_count(len(names), 'column')}"
    lines = [f"A data frame with {shape}:"]
    lines += [
        f"* {name}: {_describe_column(_column_at(frame, position))}"
        for position, name in enumerate(names[:max_columns])
    ]
    if len(names) > max_columns:
        lines.append(f"and {len(names) - max_columns} more columns")
    return "\n".join(lines)


# By position rather than by name, because pandas allows duplicate column
# names, and a name then selects a frame rather than a column.
def _column_at(frame: Any, position: int) -> Any:
    iloc = getattr(frame, "iloc", None)
    if iloc is not None:
        return iloc[:, position]
    return frame[:, position]


def _count(number: int, noun: str) -> str:
    return f"{number:,} {noun}" if number == 1 else f"{number:,} {noun}s"


def _describe_column(column: Any) -> str:
    kind = _kind(column.dtype)
    missing = _missing(column)
    described = f"{missing} missing"
    if kind in ("numeric", "temporal"):
        # A column with nothing left to take a range over says only how much
        # is missing.
        properties = (
            [described]
            if missing == len(column)
            else [
                f"range [{_value(column.min())}, {_value(column.max())}]",
                described,
            ]
        )
    elif kind == "boolean":
        true = int(column.sum())
        properties = [
            f"{true} True",
            f"{len(column) - missing - true} False",
            described,
        ]
    else:
        properties = [described]
        unique = _describe_values(column)
        if unique is not None:
            properties.append(unique)
    return f"{column.dtype} with {_flatten(properties)}"


# pandas dtypes carry a numpy `kind` character; polars dtypes answer questions
# about themselves instead. Neither library is imported here, because both are
# optional wherever a frame reaches commons.
def _kind(dtype: Any) -> str:
    kind = getattr(dtype, "kind", None)
    if kind is not None:
        if kind in "iuf":
            return "numeric"
        if kind == "b":
            return "boolean"
        if kind in "Mm":
            return "temporal"
        return "other"
    if dtype.is_numeric():
        return "numeric"
    if dtype.is_temporal():
        return "temporal"
    if str(dtype) == "Boolean":
        return "boolean"
    return "other"


def _missing(column: Any) -> int:
    if hasattr(column, "isna"):
        return int(column.isna().sum())
    return int(column.null_count())


# Like ellmer: the values themselves only when there are few and they are
# short, so a column of free text stays a count rather than a wall of prompt.
def _describe_values(column: Any) -> str | None:
    try:
        values = _unique(column)
    except TypeError:
        # Unhashable values, like a column of lists, have no unique count.
        return None
    described = _count(len(values), "unique value")
    quoted = [json.dumps(str(value), ensure_ascii=False) for value in values]
    if 0 < len(values) <= 10 and sum(len(value) for value in quoted) < 200:
        described = f"{described} ({', '.join(quoted)})"
    return described


def _unique(column: Any) -> list[Any]:
    if hasattr(column, "dropna"):
        return list(column.dropna().unique())
    return column.drop_nulls().unique(maintain_order=True).to_list()


# A timestamp at midnight is a date as far as the model is concerned, and the
# time of day is noise in a range.
def _value(value: Any) -> str:
    isoformat = getattr(value, "isoformat", None)
    if isoformat is None:
        return str(value)
    return isoformat().removesuffix("T00:00:00").replace("T", " ")


def _flatten(properties: list[str]) -> str:
    if len(properties) == 1:
        return properties[0]
    return f"{', '.join(properties[:-1])}, and {properties[-1]}"

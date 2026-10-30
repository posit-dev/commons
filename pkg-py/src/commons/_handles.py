"""Conversation-scoped store of tool results.

A later `run_python` call reaches an earlier result as a plain variable
(`r1`, `r2`, ...), so a tool's output can be built on rather than repeated.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ._frames import describe_frame, is_frame
from ._rows import rows_frame

__all__ = ["HandleStore"]


# Enough rows to work with, few enough that a runaway query cannot fill the
# conversation's memory.
MAX_HANDLE_ROWS = 10_000


@dataclass
class HandleStore:
    max_rows: int = MAX_HANDLE_ROWS
    # Frames in the store would flood a repr, and == on one raises.
    _values: dict[str, Any] = field(default_factory=dict, repr=False, compare=False)

    def register(self, value: Any) -> str | None:
        """Store a result and return the note telling the model how to reach it.

        Values that are not frames are stored too, so a scalar measure result
        stays available for further derivation.
        """
        if value is None:
            return None
        handle = f"r{len(self._values) + 1}"
        if not is_frame(value):
            self._values[handle] = value
            return _note(handle)

        try:
            truncated = len(value) > self.max_rows
            if truncated:
                value = _first_rows(value, self.max_rows)
        except (TypeError, AttributeError):
            # is_frame is duck-typed, so a value that quacks like a frame but
            # cannot be read like one is still stored, only undescribed.
            self._values[handle] = value
            return _note(handle)
        self._values[handle] = value
        capped = (
            f" Only the first {self.max_rows:,} rows are stored." if truncated else ""
        )
        try:
            description = describe_frame(value)
        except (TypeError, AttributeError):
            # A pyarrow Table, for one, is stored and capped but not described.
            return f"{_note(handle)}{capped}"
        return f"{_note(handle)}{capped}\n{description}"

    def register_rows(self, rows: list[dict[str, Any]]) -> str | None:
        """Store query rows as a data frame, as ``register`` would store one.

        Only the rows the store keeps, plus one to tell it the result was
        cut, become the frame, so a large result is never copied whole.
        """
        return self.register(rows_frame(rows[: self.max_rows + 1]))

    def ids(self) -> list[str]:
        return list(self._values)

    def get(self, handle: str) -> Any:
        return self._values[handle]


def _first_rows(frame: Any, count: int) -> Any:
    """The frame's first ``count`` rows; a pyarrow Table has no ``head``."""
    head = getattr(frame, "head", None)
    return head(count) if head is not None else frame.slice(0, count)


def _note(handle: str) -> str:
    return f"Available to `run_python` as `{handle}`."

"""Conversation-scoped store of tool results.

A later `run_python` call reaches an earlier result as a plain variable
(`r1`, `r2`, ...), so a tool's output can be built on rather than repeated.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ._frames import describe_frame, is_frame

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
                value = value.head(self.max_rows)
            description = describe_frame(value)
        except (TypeError, AttributeError):
            # is_frame is duck-typed, so a value that quacks like a frame but
            # cannot be read like one is still stored, only undescribed.
            self._values[handle] = value
            return _note(handle)
        self._values[handle] = value
        capped = (
            f" Only the first {self.max_rows:,} rows are stored." if truncated else ""
        )
        return f"{_note(handle)}{capped}\n{description}"

    def ids(self) -> list[str]:
        return list(self._values)

    def get(self, handle: str) -> Any:
        return self._values[handle]


def _note(handle: str) -> str:
    return f"Available to `run_python` as `{handle}`."

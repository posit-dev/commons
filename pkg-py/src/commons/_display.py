"""How a tool result asks to be shown in a chat UI.

shinychat reads the presentation off ``extra["display"]``, accepting either
its own ``ToolResultDisplay`` or a plain mapping it splats into one. commons
builds the mapping, so a result carries its presentation whether or not the
``shiny`` extra is installed and nothing here imports shinychat.

Icons are left out. R fills them from bsicons and renders these rows without
one when bsicons is absent, so an iconless row is a branch R already has.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

__all__ = [
    "CONTEXT_SEARCH",
    "DATA_RETRIEVAL",
    "DISPLAY_EXTRA_KEY",
    "TABLE_INSPECTION",
    "TRUSTED_CALL",
    "TRUSTED_SEARCH",
    "Title",
    "tool_display",
    "visible_result_note",
]

DISPLAY_EXTRA_KEY = "display"


@dataclass(frozen=True)
class Title:
    """What a tool row says while it runs, and once its result arrives.

    shinychat shows the tool definition's title until the result carries one
    of its own, and conjugates neither, so both tenses are written out.
    """

    running: str
    settled: str


TRUSTED_SEARCH = Title(
    "Searching for a trusted calculation", "Searched for a trusted calculation"
)
TRUSTED_CALL = Title("Running a trusted calculation", "Ran a trusted calculation")
CONTEXT_SEARCH = Title("Searching context", "Searched context")
TABLE_INSPECTION = Title("Inspecting a table", "Inspected a table")
DATA_RETRIEVAL = Title("Retrieving data", "Retrieved data")


def tool_display(
    title: str | None = None,
    *,
    html: Any = None,
    markdown: str | None = None,
    footer: Any = None,
    open: bool = False,
) -> dict[str, Any]:
    """The display envelope for a tool result.

    ``show_request`` is always off: the arguments commons sends a tool are
    its own plumbing, and a reader who wants them can open the card.
    """
    display: dict[str, Any] = {"show_request": False, "open": open}
    if title is not None:
        display["title"] = title
    if html is not None:
        display["html"] = html
    if markdown is not None:
        display["markdown"] = markdown
    if footer is not None:
        display["footer"] = footer
    return display


def visible_result_note(kind: str) -> str:
    """Tell the model the user can already see this result."""
    return (
        f"This {kind} is already visible to the user. "
        "**Do not recreate or repeat it**."
    )

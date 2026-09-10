"""How a tool result asks to be shown in a chat UI.

shinychat reads the presentation off ``extra["display"]``, accepting either
its own ``ToolResultDisplay`` or a plain mapping it splats into one. commons
builds the mapping, so a result carries its presentation whether or not the
``shiny`` extra is installed and nothing here imports shinychat.

Icons are left out. R fills them from bsicons and renders these rows without
one when bsicons is absent, so an iconless row is a branch R already has.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from typing import Any, cast

from htmltools import HTML, Tag, TagChild, TagList, div, tags

from ._frames import is_frame
from ._rows import MAX_MARKDOWN_ROWS, frame_rows, render_value

_URL = re.compile(r"https?://", re.IGNORECASE)

__all__ = [
    "CONTEXT_SEARCH",
    "DATA_RETRIEVAL",
    "DISPLAY_EXTRA_KEY",
    "TABLE_INSPECTION",
    "TRUSTED_CALL",
    "TRUSTED_SEARCH",
    "Title",
    "measure_display_html",
    "measure_display_with_custom_html",
    "measure_source_footer",
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


def measure_display_html(
    args: Mapping[str, Any],
    value: Any,
    *,
    from_query: bool = False,
    title: str | None = None,
    description: str | None = None,
) -> Tag:
    """The card behind a trusted calculation: what ran, with what, and the answer.

    Built as tags rather than assembled text, so every value a measure or the
    model supplied is escaped by htmltools on the way in.

    ``from_query`` says the value is rows a data source answered with. It
    cannot be guessed: an empty list is an empty result to a query and an
    empty answer to a measure, and the two read differently.
    """
    return div(
        _metadata_html(title, description),
        _args_html(args),
        div(
            tags.strong("Result"),
            div(
                _value_html(value, from_query),
                class_="commons-measure-result-value",
            ),
            class_="commons-measure-result",
        ),
        class_="commons-measure-display",
    )


def measure_display_with_custom_html(
    args: Mapping[str, Any],
    html: Any,
    *,
    title: str | None = None,
    description: str | None = None,
) -> Tag:
    """The standard measure card around HTML a measure authored for itself.

    What commons knows heads the card -- the measure's metadata and the
    arguments it ran with -- and the authored markup is the result. A string
    is markup the measure wrote, not text to escape; a tag tree keeps the
    dependencies attached to it.
    """
    if isinstance(html, str):
        html = HTML(html)
    return div(
        _metadata_html(title, description),
        _args_html(args),
        div(
            tags.strong("Result"),
            div(
                html,
                class_="commons-measure-result-value "
                "commons-measure-result-value-authored",
            ),
            class_="commons-measure-result",
        ),
        class_="commons-measure-display",
    )


def measure_source_footer(provenance: Iterable[str]) -> TagList | None:
    """Links back to wherever the measure's definition came from.

    Only the URLs in `provenance` become links; the rest of it is prose for
    the model rather than something a reader can follow.
    """
    urls = list(dict.fromkeys(url for url in provenance if _URL.match(url)))
    if not urls:
        return None
    return TagList(
        *(
            tags.a(
                "View source" if len(urls) == 1 else f"Source {position}",
                class_="commons-measure-source-link",
                href=url,
                target="_blank",
                # A chat app loses its session when a link navigates the page.
                rel="noopener noreferrer",
            )
            for position, url in enumerate(urls, start=1)
        )
    )


# Roughly three lines at chat-card width; the stylesheet supplies the exact
# clamp, so a description longer than this is repeated behind a disclosure.
_DETAILS_THRESHOLD = 200


def _metadata_html(title: str | None, description: str | None) -> Tag | None:
    if not title:
        return None
    details = (
        description if description and len(description) > _DETAILS_THRESHOLD else None
    )
    return div(
        div(
            tags.strong(title, class_="commons-measure-title"),
            div(
                description,
                class_="commons-measure-description"
                + (" commons-measure-description-summary" if details else ""),
            )
            if description
            else None,
            _details_html(details) if details else None,
            class_="commons-measure-metadata-item",
        ),
        class_="commons-measure-metadata",
    )


def _details_html(details: str) -> Tag:
    """A long description behind a See more disclosure the stylesheet fades in."""
    return tags.details(
        tags.summary(
            tags.span("See more", class_="commons-measure-details-more"),
            tags.span("See less", class_="commons-measure-details-less"),
        ),
        div(details, class_="commons-measure-details-body"),
        class_="commons-measure-details",
    )


def _args_html(args: Mapping[str, Any]) -> Tag | None:
    if not args:
        return None
    return div(
        *(
            div(
                tags.span(f"{_label(name)}:", class_="commons-measure-arg-name"),
                " ",
                tags.span(_format_arg(value), class_="commons-measure-arg-value"),
                class_="commons-measure-arg",
            )
            for name, value in args.items()
        ),
        class_="commons-measure-args",
    )


def _value_html(value: Any, from_query: bool) -> TagChild:
    rows = _as_rows(value, from_query)
    if rows is None:
        return render_value(value)
    if not rows:
        # The same words the model is given, so the card cannot disagree.
        return "No rows."
    # Union rather than the first row's keys: a driver may omit a null column.
    columns = list(dict.fromkeys(key for row in rows for key in row))
    shown = rows[:MAX_MARKDOWN_ROWS]
    return TagList(
        tags.table(
            tags.thead(tags.tr(*(tags.th(column) for column in columns))),
            tags.tbody(
                *(
                    tags.tr(
                        *(tags.td(render_value(row.get(c))) for c in columns)
                    )
                    for row in shown
                )
            ),
        ),
        tags.p(f"{len(rows) - len(shown)} more rows not shown")
        if len(rows) > len(shown)
        else None,
    )


def _as_rows(value: Any, from_query: bool) -> list[Mapping[str, Any]] | None:
    """The rows behind a value, whether it arrived as a frame or as rows."""
    if is_frame(value):
        return cast("list[Mapping[str, Any]] | None", frame_rows(value))
    if from_query and isinstance(value, list):
        return value
    return None


def _label(name: str) -> str:
    """An argument name as a reader would write it."""
    spelled = name.replace("_", " ")
    return spelled[:1].upper() + spelled[1:]


def _format_arg(value: Any) -> str:
    if isinstance(value, (list, tuple)):
        return ", ".join(_format_arg(item) for item in value)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return f"{value:,.0f}" if float(value).is_integer() else f"{value:,}"
    return render_value(value)

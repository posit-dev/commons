"""Plots and styled tables that a measure returns, shown to the model and the user.

A matplotlib figure or a plotnine plot is drawn as an image for both readers.
A great_tables table is rendered as HTML for the user, while the model and
the handle store get the data behind it. What the model reads is pinned by
``tests/shared/measure-rich-results.json``.

Nothing here imports matplotlib, plotnine, or great_tables: a value can only
be one of their objects if its library is already loaded.
"""

from __future__ import annotations

import base64
import io
import sys
from collections.abc import Callable, Mapping
from typing import Any

from chatlas import ContentToolResult
from chatlas.types import ContentImageInline, ContentText
from htmltools import HTML, tags

from ._citations import tool_result
from ._display import (
    TRUSTED_CALL,
    measure_display_with_result_html,
    visible_result_note,
)
from ._execution._protocol import PLOT_BYTES_LIMIT
from ._frames import describe_frame, is_frame
from ._handles import HandleStore
from ._measures import Measure
from ._provenance import Tag
from ._rows import frame_rows, rows_to_markdown

__all__ = ["rich_measure_result"]

# The longest edge of the model's image; providers scale larger ones down.
MODEL_LONG_EDGE = 1568

# How many times the display image's pixels exceed the model image's.
DISPLAY_SCALE = 2

TABLE_HANDLE_NOTE = (
    "For calculations, use `run_python` with the table handle below instead "
    "of parsing values from the rendered table."
)


def rich_measure_result(
    value: Any,
    args: Mapping[str, Any],
    record: Measure,
    handles: HandleStore,
    footer: Any,
) -> ContentToolResult | None:
    """The result for a plot or a styled table, or ``None`` for any other value."""
    card = _Card(args, record, footer)
    if _is_instance(value, "great_tables", "GT"):
        return _table_result(value, card, handles)
    if _is_instance(value, "plotnine", "ggplot"):
        # The plot's data is what code can compute with; the figure it draws
        # would reach run_python only as text.
        data = value.data if is_frame(value.data) else None
        return _plot_result(value.draw, data, card, handles)
    if _is_instance(value, "matplotlib.figure", "Figure"):
        return _plot_result(lambda: value, None, card, handles)
    return None


class _Card:
    """What every rich result's display shares: the measure and its arguments."""

    def __init__(self, args: Mapping[str, Any], record: Measure, footer: Any) -> None:
        self.args = args
        self.record = record
        self.footer = footer

    def result(
        self, value: Any, html: Any, value_class: str | None = None
    ) -> ContentToolResult:
        return tool_result(
            value,
            Tag.A,
            title=TRUSTED_CALL.settled,
            html=measure_display_with_result_html(
                self.args,
                html,
                title=self.record.title,
                description=self.record.description,
                value_class=value_class,
            ),
            footer=self.footer,
            open=True,
        )

    def failure(
        self,
        kind: str,
        exc: Exception,
        advert: str | None,
        value_class: str,
        model_content: str | None = None,
    ) -> ContentToolResult:
        note = (
            f"The measure returned {kind}, but it could not be displayed: "
            f"{str(exc) or type(exc).__name__}"
        )
        value = "\n\n".join(part for part in (model_content, note, advert) if part)
        return self.result(value, note, value_class)


def _plot_result(
    draw: Callable[[], Any], data: Any, card: _Card, handles: HandleStore
) -> ContentToolResult:
    advert = handles.register(data)
    figure = None
    try:
        figure = draw()
        png, display_png = _pngs(figure)
        if len(png) + len(display_png) > PLOT_BYTES_LIMIT:
            raise ValueError(
                f"its images total more than {PLOT_BYTES_LIMIT // 2**20} MiB"
            )
    except Exception as exc:  # noqa: BLE001 - any drawing failure is reported, not raised
        return card.failure("a plot", exc, advert, "commons-measure-plot-error")
    finally:
        _close(figure)

    width = int.from_bytes(png[16:20], "big")
    height = int.from_bytes(png[20:24], "big")
    image = tags.img(
        class_="commons-measure-plot",
        src="data:image/png;base64," + base64.b64encode(display_png).decode("ascii"),
        alt=f"Plot returned by {card.record.title}",
        width=str(width),
        height=str(height),
    )
    value: list[Any] = [
        ContentText(text=visible_result_note("plot")),
        ContentImageInline(
            image_content_type="image/png",
            data=base64.b64encode(png).decode("ascii"),
        ),
    ]
    if advert:
        value.append(ContentText(text=advert))
    return card.result(value, image)


def _table_result(table: Any, card: _Card, handles: HandleStore) -> ContentToolResult:
    data = getattr(table, "_tbl_data", None)
    if not is_frame(data):
        raise ValueError(
            "Can't recover data from the great_tables table returned by the measure."
        )
    advert = handles.register(data)
    rows = frame_rows(data)
    content = rows_to_markdown(rows) if rows is not None else describe_frame(data)
    try:
        html = table.as_raw_html()
    except Exception as exc:  # noqa: BLE001 - any rendering failure is reported, not raised
        return card.failure(
            "a gt table", exc, advert, "commons-measure-gt-table-error", content
        )

    note = visible_result_note("gt table")
    if advert:
        note = f"{note} {TABLE_HANDLE_NOTE}"
    value = "\n\n".join(part for part in (note, content, advert) if part)
    return card.result(value, HTML(html), "commons-measure-gt-table")


def _is_instance(value: Any, module: str, name: str) -> bool:
    loaded = sys.modules.get(module)
    cls = getattr(loaded, name, None)
    return isinstance(cls, type) and isinstance(value, cls)


def _pngs(figure: Any) -> tuple[bytes, bytes]:
    """``figure`` as a PNG for the model and one with twice the pixels for display.

    The model image keeps the figure's own size, scaled down to fit the
    model's limit.
    """
    width, height = figure.get_size_inches()
    dpi = min(float(figure.dpi), MODEL_LONG_EDGE / max(width, height))
    return _png(figure, dpi), _png(figure, dpi * DISPLAY_SCALE)


def _png(figure: Any, dpi: float) -> bytes:
    # A tight bounding box would let the image grow past the size ``dpi`` was
    # chosen for.
    matplotlib = sys.modules["matplotlib"]
    buffer = io.BytesIO()
    with matplotlib.rc_context({"savefig.bbox": "standard"}):
        figure.savefig(buffer, format="png", dpi=dpi)
    return buffer.getvalue()


def _close(figure: Any) -> None:
    """Release a figure pyplot is tracking, so repeated calls do not pile up."""
    pyplot = sys.modules.get("matplotlib.pyplot")
    if figure is not None and pyplot is not None:
        pyplot.close(figure)

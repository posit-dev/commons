"""Plot capture: the figures a call shows or leaves open, rendered as PNGs and closed.

matplotlib keeps every figure until it is closed. ``flush`` renders the
figures pyplot is tracking into the call's transcript and closes them, as
Jupyter's inline backend does. ``plt.show()`` flushes at that point in the
output, and the worker flushes once more when the call ends, so a plot sits
between the text written before and after it. Each figure is rendered twice:
once for the model, at its own size, and once at twice the pixels for
display. Figures built without pyplot (``matplotlib.figure.Figure()``) are
not tracked and do not come back.

Nothing here imports matplotlib. A call that never imported pyplot has no
figures, and the worker does not pay for the import on its behalf.
"""

from __future__ import annotations

import io
import sys
from typing import Any

import _protocol  # pyrefly: ignore[missing-import]

__all__ = ["BACKEND", "begin", "end", "flush"]

# The value for MPLBACKEND, naming the sibling module by its import name.
BACKEND = "module://_figure_backend"

# The longest edge of a model image. Larger images are scaled down by the
# provider anyway, so the extra pixels would only cost channel space.
_MODEL_LONG_EDGE = 1568

# How many times the display image's pixels exceed the model image's.
_DISPLAY_SCALE = 2

# The most of an exception's repr a note keeps. Notes bypass the capture's
# bound so they are never lost, which makes them bounded here instead.
_DESCRIPTION_LIMIT = 500


class _Call:
    """The plot state of the call in flight: where plots go, and what they used."""

    def __init__(self, transcript: Any) -> None:
        self.transcript = transcript
        self.figures = 0
        self.plots = 0
        self.size = 0
        self.full = False


_call: _Call | None = None


def begin(transcript: Any) -> None:
    """Send the next call's plots, and notes about them, to ``transcript``."""
    global _call
    _call = _Call(transcript)


def end() -> None:
    """Close whatever figures remain, so none carries into the next call."""
    global _call
    _call = None
    _close_all()


def flush() -> None:
    """Render every open figure into the call's transcript, then close them all.

    Model code can run inside ``savefig`` (an artist's ``draw``) and can
    replace pyplot's own functions, so no failure here may escape: a broken
    figure costs that figure, and a broken pyplot costs the plots, never the
    session. Each failure, and the point where the call ran past
    ``PLOT_LIMIT`` or ``PLOT_BYTES_LIMIT``, is noted on stderr where it
    happened. ``KeyboardInterrupt`` propagates; the worker then discards the
    figures.
    """
    call = _call
    pyplot = sys.modules.get("matplotlib.pyplot")
    if call is None or pyplot is None:
        return
    try:
        figures = [pyplot.figure(number) for number in pyplot.get_fignums()]
    except KeyboardInterrupt:
        raise
    except BaseException as exc:  # noqa: BLE001 - model code can break pyplot
        _note(call, f"the figures could not be collected: {_describe(exc)}")
        _close_all()
        return
    for figure in figures:
        call.figures += 1
        if call.full:
            break
        if call.plots >= _protocol.PLOT_LIMIT:
            _note(
                call,
                f"figures {call.figures} onward were dropped; a call returns "
                f"at most {_protocol.PLOT_LIMIT}",
            )
            call.full = True
            break
        try:
            plot = _render(figure)
        except KeyboardInterrupt:
            raise
        except BaseException as exc:  # noqa: BLE001 - one figure, not the call
            _note(
                call, f"figure {call.figures} could not be rendered: {_describe(exc)}"
            )
            continue
        size = len(plot.png) + len(plot.display_png)
        if call.size + size > _protocol.PLOT_BYTES_LIMIT:
            # Checked as each figure renders, so at most one figure past the
            # budget is ever held in memory.
            _note(
                call,
                f"figures {call.figures} onward were dropped; their images "
                "exceeded the channel's room for plots",
            )
            call.full = True
            break
        call.size += size
        call.plots += 1
        call.transcript.insert(plot)
    _close_all()


def _note(call: _Call, text: str) -> None:
    call.transcript.note("stderr", f"[commons: {text}]\n")


def _close_all() -> None:
    """Close every open figure."""
    pyplot = sys.modules.get("matplotlib.pyplot")
    if pyplot is None:
        return
    try:
        pyplot.close("all")
    except KeyboardInterrupt:
        raise
    except BaseException:  # noqa: BLE001, S110 - model code can break pyplot
        # A figure left open costs nothing more than the figure.
        pass


def _describe(exc: BaseException) -> str:
    """``exc``'s repr, clipped, or its type's name when model code made it fail."""
    try:
        text = str(repr(exc))
        if len(text) > _DESCRIPTION_LIMIT:
            return text[:_DESCRIPTION_LIMIT] + "…"
        return text
    except KeyboardInterrupt:
        raise
    except BaseException:  # noqa: BLE001 - the fallback is the type name
        try:
            return str(type(exc).__name__)
        except BaseException:  # noqa: BLE001 - the fallback is a fixed text
            return "an exception"


def _render(figure: Any) -> _protocol.Plot:
    """``figure`` as a model PNG at its own size, scaled down to fit, and a display PNG.

    Both images are checked before they are kept: model code can replace
    ``savefig``, and a reply carrying something that is not a plot would
    cost the session rather than the figure.
    """
    width, height = figure.get_size_inches()
    dpi = min(float(figure.dpi), _MODEL_LONG_EDGE / max(width, height))
    plot = _protocol.Plot(
        png=_png(figure, dpi), display_png=_png(figure, dpi * _DISPLAY_SCALE)
    )
    _protocol.png_size(plot.png)
    _protocol.png_size(plot.display_png)
    return plot


def _png(figure: Any, dpi: float) -> bytes:
    """``figure`` saved as a PNG at ``dpi``, at exactly its own size.

    A tight bounding box or padding from rcParams would let the image grow
    past the size ``dpi`` was chosen for, so both are reset for the save.
    """
    matplotlib = sys.modules["matplotlib"]
    buffer = io.BytesIO()
    with matplotlib.rc_context({"savefig.bbox": "standard"}):
        figure.savefig(buffer, format="png", dpi=dpi)
    return buffer.getvalue()

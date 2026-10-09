"""Plot capture: the figures a call leaves open, rendered as PNGs and closed.

matplotlib keeps every figure until it is closed, so after each call the
worker renders the figures pyplot is tracking and then closes them all, as
Jupyter's inline backend does. Each figure is rendered twice: once for the
model, at its own size, and once at twice the pixels for display. Figures
built without pyplot (``matplotlib.figure.Figure()``) are not tracked and
do not come back.

Nothing here imports matplotlib. A call that never imported pyplot has no
figures, and the worker does not pay for the import on its behalf.
"""

from __future__ import annotations

import io
import sys
from typing import Any

import _protocol  # pyrefly: ignore[missing-import]

__all__ = ["BACKEND", "collect", "discard"]

# The value for MPLBACKEND, naming the sibling module by its import name.
BACKEND = "module://_figure_backend"

# The longest edge of a model image. Larger images are scaled down by the
# provider anyway, so the extra pixels would only cost channel space.
_MODEL_LONG_EDGE = 1568

# How many times the display image's pixels exceed the model image's.
_DISPLAY_SCALE = 2


def collect() -> tuple[tuple[_protocol.Plot, ...], str]:
    """Render and close every open figure, and say what did not come back.

    Returns the plots in the order the figures were made, and a note for the
    call's stderr naming any figure that failed to render or fell past
    ``PLOT_LIMIT``. Model code can run inside ``savefig`` (an artist's
    ``draw``) and can replace pyplot's own functions, so no failure here
    may escape: a broken figure costs that figure, and a broken pyplot
    costs the plots, never the session.
    ``KeyboardInterrupt`` propagates; the caller then discards the figures.
    """
    pyplot = sys.modules.get("matplotlib.pyplot")
    if pyplot is None:
        return (), ""
    try:
        figures = [pyplot.figure(number) for number in pyplot.get_fignums()]
    except KeyboardInterrupt:
        raise
    except BaseException as exc:  # noqa: BLE001 - model code can break pyplot
        discard()
        return (), f"[commons: the figures could not be collected: {exc!r}]\n"
    notes = []
    if len(figures) > _protocol.PLOT_LIMIT:
        notes.append(
            f"[commons: the call left {len(figures)} figures open; only the "
            f"first {_protocol.PLOT_LIMIT} came back]"
        )
    plots = []
    size = 0
    for index, figure in enumerate(figures[: _protocol.PLOT_LIMIT], start=1):
        try:
            plot = _render(figure)
        except KeyboardInterrupt:
            raise
        except BaseException as exc:  # noqa: BLE001 - one figure, not the call
            notes.append(f"[commons: figure {index} could not be rendered: {exc!r}]")
            continue
        size += len(plot.png) + len(plot.display_png)
        if size > _protocol.PLOT_BYTES_LIMIT:
            # Checked as each figure renders, so at most one figure past the
            # budget is ever held in memory.
            notes.append(
                f"[commons: figures {index} onward were dropped; their images "
                "exceeded the channel's room for plots]"
            )
            break
        plots.append(plot)
    discard()
    return tuple(plots), "".join(note + "\n" for note in notes)


def discard() -> None:
    """Close every open figure, so none carries into the next call."""
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


def _render(figure: Any) -> _protocol.Plot:
    """``figure`` as a model PNG at its own size, scaled down to fit, and a display PNG."""
    width, height = figure.get_size_inches()
    dpi = min(float(figure.dpi), _MODEL_LONG_EDGE / max(width, height))
    return _protocol.Plot(
        png=_png(figure, dpi), display_png=_png(figure, dpi * _DISPLAY_SCALE)
    )


def _png(figure: Any, dpi: float) -> bytes:
    buffer = io.BytesIO()
    figure.savefig(buffer, format="png", dpi=dpi)
    return buffer.getvalue()

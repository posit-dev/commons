"""The matplotlib backend the worker selects: Agg rendering, and an inline ``show()``.

``show()`` puts the open figures into the call's output at that point, as
Jupyter's inline backend does (see ``_plots``). Under plain Agg it would
warn that the backend is non-interactive instead. matplotlib imports this
module by name, through ``MPLBACKEND``, the first time pyplot needs a
backend.
"""

from __future__ import annotations

import _plots  # pyrefly: ignore[missing-import]
from matplotlib.backend_bases import FigureManagerBase
from matplotlib.backends.backend_agg import FigureCanvasAgg


class FigureManager(FigureManagerBase):
    """Shows a figure the way ``show()`` below does, for ``fig.show()``."""

    def show(self) -> None:
        _plots.flush()


class FigureCanvas(FigureCanvasAgg):
    manager_class = FigureManager


def show(*args: object, **kwargs: object) -> None:
    """Put the open figures into the call's output here, and close them."""
    _plots.flush()

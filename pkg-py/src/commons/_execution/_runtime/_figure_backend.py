"""The matplotlib backend the worker selects: Agg rendering, and a quiet ``show()``.

The worker collects every open figure after each call (see ``_plots``), so
``show()`` has nothing to do. Under plain Agg it would warn that the backend
is non-interactive, and that warning would reach the model on every script
that ends the usual way. matplotlib imports this module by name, through
``MPLBACKEND``, the first time pyplot needs a backend.
"""

from __future__ import annotations

from matplotlib.backends.backend_agg import FigureCanvasAgg

FigureCanvas = FigureCanvasAgg


def show(*args: object, **kwargs: object) -> None:
    """Do nothing: the figures come back with the call's reply."""

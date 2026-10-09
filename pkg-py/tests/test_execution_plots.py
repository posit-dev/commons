"""Plot capture: the figures a call draws come back with its reply.

Every test runs a real worker with real matplotlib; nothing is mocked. The
module skips where matplotlib is not installed or the host cannot sandbox
the worker.
"""

from __future__ import annotations

import os

import pytest

from commons._execution._driver import Worker
from commons._execution._protocol import PLOT_LIMIT, Error, Result
from commons._execution._sandbox import protection_mode

pytest.importorskip("matplotlib")

try:
    _PROTECTION = protection_mode()
except RuntimeError:
    _PROTECTION = None

pytestmark = [
    pytest.mark.skipif(
        _PROTECTION is None, reason="this host cannot sandbox the worker"
    ),
    pytest.mark.skipif(
        os.name != "posix", reason="the interrupt escalation is POSIX-shaped"
    ),
]

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# The first matplotlib import in a fresh worker builds its font cache.
CALL_TIMEOUT = 30


def make_worker(**kwargs) -> Worker:
    kwargs.setdefault("call_timeout", CALL_TIMEOUT)
    kwargs.setdefault("interrupt_grace", 2)
    return Worker(**kwargs)


PLOT = """
import matplotlib.pyplot as plt
plt.plot([1, 2, 3], [1, 4, 9])
"""


async def test_a_figure_the_call_draws_comes_back_as_a_plot():
    async with make_worker() as worker:
        reply = await worker.run(PLOT)
        assert isinstance(reply, Result), reply
        [plot] = reply.plots
        assert plot.png.startswith(PNG_SIGNATURE)
        assert plot.display_png.startswith(PNG_SIGNATURE)
        # matplotlib's default figure is 6.4 x 4.8 inches at 100 dpi.
        assert (plot.width, plot.height) == (640, 480)


async def test_the_display_image_has_twice_the_pixels_of_the_model_image():
    async with make_worker() as worker:
        reply = await worker.run(PLOT)
        assert isinstance(reply, Result), reply
        [plot] = reply.plots
        display_width = int.from_bytes(plot.display_png[16:20], "big")
        display_height = int.from_bytes(plot.display_png[20:24], "big")
        assert (display_width, display_height) == (2 * plot.width, 2 * plot.height)


async def test_showing_a_figure_is_quiet_and_still_returns_it():
    # `plt.show()` is what a script ends with; under a non-interactive
    # backend matplotlib would warn that it cannot show anything.
    async with make_worker() as worker:
        reply = await worker.run(PLOT + "plt.show()\n")
        assert isinstance(reply, Result), reply
        assert len(reply.plots) == 1
        assert reply.stderr == ""


async def test_a_figure_comes_back_once_and_not_with_the_next_call():
    async with make_worker() as worker:
        await worker.run(PLOT)
        reply = await worker.run("1 + 1")
        assert isinstance(reply, Result), reply
        assert reply.plots == ()


async def test_several_figures_come_back_in_the_order_they_were_made():
    code = """
import matplotlib.pyplot as plt
plt.figure(figsize=(2, 1))
plt.figure(figsize=(3, 1))
"""
    async with make_worker() as worker:
        reply = await worker.run(code)
        assert isinstance(reply, Result), reply
        assert [plot.width for plot in reply.plots] == [200, 300]


async def test_a_call_that_raises_still_returns_what_it_drew():
    async with make_worker() as worker:
        reply = await worker.run(PLOT + "raise ValueError('after the plot')\n")
        assert isinstance(reply, Error), reply
        assert len(reply.plots) == 1
        follow_up = await worker.run("1")
        assert isinstance(follow_up, Result)
        assert follow_up.plots == ()


async def test_figures_past_the_limit_are_dropped_with_a_note():
    code = f"""
import matplotlib.pyplot as plt
for _ in range({PLOT_LIMIT + 3}):
    plt.figure(figsize=(1, 1))
"""
    async with make_worker() as worker:
        reply = await worker.run(code)
        assert isinstance(reply, Result), reply
        assert len(reply.plots) == PLOT_LIMIT
        assert f"{PLOT_LIMIT + 3} figures" in reply.stderr


async def test_a_huge_figure_is_scaled_down_for_the_model():
    # A figure's size is the model's to choose, and a poster-sized one would
    # cost far more image tokens than it is worth.
    code = """
import matplotlib.pyplot as plt
plt.figure(figsize=(40, 10), dpi=300)
"""
    async with make_worker() as worker:
        reply = await worker.run(code)
        assert isinstance(reply, Result), reply
        [plot] = reply.plots
        assert plot.width == 1568
        assert plot.height == 392


async def test_a_figure_that_cannot_be_drawn_is_reported_and_the_rest_return():
    code = """
import matplotlib.pyplot as plt
from matplotlib.artist import Artist

class Broken(Artist):
    def draw(self, renderer):
        raise RuntimeError("cannot draw this")

plt.figure().add_artist(Broken())
plt.figure()
"""
    async with make_worker() as worker:
        reply = await worker.run(code)
        assert isinstance(reply, Result), reply
        assert len(reply.plots) == 1
        assert "cannot draw this" in reply.stderr
        follow_up = await worker.run("1")
        assert isinstance(follow_up, Result)
        assert follow_up.plots == ()


async def test_an_interrupted_call_leaves_no_figure_for_the_next_one():
    async with make_worker() as worker:
        # Pay the font cache in a call of its own, so the timeout below
        # interrupts the loop rather than the import.
        await worker.run("import matplotlib.pyplot as plt")
        worker._call_timeout = 1
        await worker.run(PLOT + "while True:\n    pass\n")
        reply = await worker.run("1")
        assert isinstance(reply, Result), reply
        assert reply.plots == ()


async def test_code_that_never_plots_does_not_load_matplotlib():
    async with make_worker() as worker:
        reply = await worker.run("import sys; 'matplotlib' in sys.modules")
        assert isinstance(reply, Result), reply
        assert reply.value is False


async def test_a_broken_pyplot_costs_the_plots_and_not_the_session():
    code = """
import matplotlib.pyplot as plt
x = 41
plt.get_fignums = lambda: 1 / 0
"""
    async with make_worker() as worker:
        reply = await worker.run(code)
        assert isinstance(reply, Result), reply
        assert reply.plots == ()
        assert "ZeroDivisionError" in reply.stderr
        follow_up = await worker.run("x + 1")
        assert isinstance(follow_up, Result)
        assert follow_up.value == 42


async def test_figures_too_large_for_the_channel_are_dropped_with_a_note():
    # Noise does not compress, so each display image is tens of megabytes.
    code = """
import numpy as np
import matplotlib.pyplot as plt
for _ in range(2):
    plt.figure(figsize=(16, 16), dpi=98)
    plt.imshow(np.random.default_rng(0).random((1600, 1600, 3)))
    plt.axis("off")
x = 42
"""
    async with make_worker() as worker:
        reply = await worker.run(code)
        assert isinstance(reply, Result), reply
        assert reply.plots == ()
        assert "figures 1 onward were dropped" in reply.stderr
        follow_up = await worker.run("x")
        assert isinstance(follow_up, Result)
        assert follow_up.value == 42


async def test_a_pyplot_whose_close_raises_systemexit_keeps_the_session():
    code = """
import matplotlib.pyplot as plt
import sys
x = 41
plt.figure()
plt.close = lambda *args: sys.exit(1)
"""
    async with make_worker() as worker:
        reply = await worker.run(code)
        assert isinstance(reply, Result), reply
        follow_up = await worker.run("x + 1")
        assert isinstance(follow_up, Result)
        assert follow_up.value == 42

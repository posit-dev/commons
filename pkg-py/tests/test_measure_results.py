"""Plots and styled tables a measure returns, driven by the shared fixture.

What the model and the user get from a measure that returns a plot or a
styled table is a cross-language contract, so the cases live in
``tests/shared/measure-rich-results.json`` and the R suite runs the same ones.
Do not restate a case here; add it to the fixture. The plotnine tests below
cover what only Python has.
"""

from __future__ import annotations

from typing import Any

import pandas as pd
import pytest
from chatlas import ContentToolResult
from chatlas.types import ContentImageInline, ContentText

from commons import data_source, measure
from commons._display import DISPLAY_EXTRA_KEY
from commons._frames import is_frame
from commons._handles import HandleStore
from commons._measures import as_measure
from commons._provenance import TAG_EXTRA_KEY, Tag
from commons._tools import ToolContext, build_commons_tools

from ._shared import load_shared_fixture

SPEC: dict[str, Any] = load_shared_fixture("measure-rich-results")
SUBSTITUTIONS: dict[str, str] = SPEC["substitutions"]["python"]

pytest.importorskip("matplotlib")
pytest.importorskip("great_tables")


def call_returning(value: Any, title: str) -> tuple[ContentToolResult, HandleStore]:
    """Call, through call_measure, a measure titled ``title`` that returns ``value``."""

    @measure(description="A measure under test.", title=title)
    def returned() -> Any:
        return value

    found = as_measure(returned)
    assert found is not None
    handles = HandleStore()
    tools = build_commons_tools(
        ToolContext(
            sources={"data": data_source(t=pd.DataFrame({"x": [1]}))},
            measures={found.name: found},
            handles=handles,
        )
    )
    tool = next(tool for tool in tools if tool.name == "call_measure")
    result = tool.func(name=found.name, arguments="{}")
    assert isinstance(result, ContentToolResult)
    return result, handles


def model_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    return "\n\n".join(part.text for part in value if isinstance(part, ContentText))


def image_count(value: Any) -> int:
    if isinstance(value, str):
        return 0
    return sum(isinstance(part, ContentImageInline) for part in value)


def test_the_fixture_has_cases() -> None:
    assert SPEC["cases"]["cases"]


@pytest.mark.parametrize("case", SPEC["cases"]["cases"], ids=lambda case: case["name"])
def test_rich_measure_results_follow_the_shared_fixture(case: dict[str, Any]) -> None:
    namespace: dict[str, Any] = {}
    exec(case["value"]["python"], namespace)  # noqa: S102 - fixture code, not input
    result, handles = call_returning(namespace["value"], case["title"])
    expect = case["expect"]
    text = model_text(result.value)
    html = str(result.extra[DISPLAY_EXTRA_KEY]["html"])

    if "note" in expect:
        note = SPEC["notes"][expect["note"]].format(**SUBSTITUTIONS)
        assert text.startswith(note)
    if "failure" in expect:
        assert SPEC["notes"]["failure"].format(kind=expect["failure"]) in text
    if "contains" in expect:
        assert expect["contains"] in text
    assert image_count(result.value) == expect["images"]
    assert expect["class"] in html
    if expect.get("alt"):
        assert f'alt="{SPEC["alt"].format(title=case["title"])}"' in html
    if expect.get("frame_handle"):
        assert is_frame(handles.get("r1"))
    assert result.extra[TAG_EXTRA_KEY] is Tag.A
    assert result.extra[DISPLAY_EXTRA_KEY]["open"] is True


def test_a_plotnine_plot_is_drawn_and_keeps_its_data() -> None:
    plotnine = pytest.importorskip("plotnine")
    data = pd.DataFrame({"x": [1, 2, 3], "y": [2, 4, 3]})
    plot = plotnine.ggplot(data, plotnine.aes("x", "y")) + plotnine.geom_point()

    result, handles = call_returning(plot, "Revenue plot")

    assert image_count(result.value) == 1
    assert "Available to `run_python` as `r1`" in model_text(result.value)
    assert handles.get("r1").equals(data)


def test_a_plotnine_plot_that_cannot_be_drawn_says_why() -> None:
    plotnine = pytest.importorskip("plotnine")
    data = pd.DataFrame({"x": [1, 2, 3]})
    plot = plotnine.ggplot(data, plotnine.aes("x", "y")) + plotnine.geom_point()

    result, _ = call_returning(plot, "Revenue plot")

    failure = SPEC["notes"]["failure"].format(kind="a plot")
    assert failure in model_text(result.value)
    assert image_count(result.value) == 0


def test_a_matplotlib_figure_gets_no_handle() -> None:
    from matplotlib.figure import Figure

    figure = Figure()
    figure.add_subplot().plot([1, 2], [3, 4])

    result, handles = call_returning(figure, "Revenue plot")

    assert "run_python" not in model_text(result.value)
    assert handles.ids() == []


def test_a_pyplot_figure_is_closed_once_it_is_drawn() -> None:
    import matplotlib

    matplotlib.use("Agg")
    from matplotlib import pyplot

    figure = pyplot.figure()
    figure.add_subplot().plot([1, 2], [3, 4])

    call_returning(figure, "Revenue plot")

    assert figure.number not in pyplot.get_fignums()


def test_a_plot_too_large_to_send_says_so(monkeypatch) -> None:
    # Lowering the limit stands in for a figure whose PNGs run to many
    # megabytes, which would take seconds to draw.
    import commons._measure_results

    monkeypatch.setattr(commons._measure_results, "PLOT_BYTES_LIMIT", 1024)
    from matplotlib.figure import Figure

    figure = Figure()
    figure.add_subplot().plot([1, 2], [3, 4])

    result, _ = call_returning(figure, "Revenue plot")

    text = model_text(result.value)
    assert SPEC["notes"]["failure"].format(kind="a plot") in text
    assert "MiB" in text
    assert image_count(result.value) == 0

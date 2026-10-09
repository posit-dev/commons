"""run_python: its description, the result it builds, and calls through an agent."""

from __future__ import annotations

import base64
import importlib.util
from pathlib import Path
from typing import Any

import pandas as pd
import pytest
from chatlas import ContentToolRequest, ContentToolResult, Tool
from chatlas.types import ContentImageInline, ContentText

from commons import Injected, data_source, measure, semantic_layer
from commons._agent import Commons
from commons._display import DISPLAY_EXTRA_KEY
from commons._execution._driver import Failure
from commons._execution._protocol import Error, OpaqueValue, Plot, Result
from commons._provenance import TAG_EXTRA_KEY, Tag
from commons._run_python import (
    NO_OUTPUT,
    highlight_python,
    run_python_description,
    run_python_result,
    session_can_import,
)

from ._provider import scripted_chat, text


@measure(description="Total revenue.")
def total_revenue(sales: Injected[Any]) -> float:
    return float(sales.execute("SELECT SUM(revenue) FROM sales").fetchone()[0])


def frame() -> pd.DataFrame:
    return pd.DataFrame({"revenue": [500.0, 900.0, 300.0]})


def png(width: int, height: int) -> bytes:
    """A PNG signature and IHDR header of the given size, which is all Plot reads."""
    header = width.to_bytes(4, "big") + height.to_bytes(4, "big")
    return (
        b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + header + b"\x08\x06\x00\x00\x00"
    )


def plot() -> Plot:
    return Plot(png=png(400, 300), display_png=png(800, 600))


def display(result: ContentToolResult) -> dict[str, Any]:
    assert result.extra is not None
    return result.extra[DISPLAY_EXTRA_KEY]


def tool_request(**arguments: Any) -> list[Any]:
    return [
        ContentToolRequest(id="call-run_python", name="run_python", arguments=arguments)
    ]


def run_python_tool(agent: Commons) -> Tool:
    tool = {tool.name: tool for tool in agent.get_tools()}["run_python"]
    assert isinstance(tool, Tool)
    return tool


def tool_results(agent: Commons) -> list[ContentToolResult]:
    return [
        content
        for turn in agent.get_turns()
        for content in turn.contents
        if isinstance(content, ContentToolResult)
    ]


# ---- the description --------------------------------------------------------


def test_the_preloaded_handles_name_the_registered_tools_that_store_results() -> None:
    description = run_python_description(
        ["search_pool", "call_measure", "run_sql"], has_measures=True, network="none"
    )
    assert "Results from call_measure and run_sql are preloaded" in description
    description = run_python_description(
        ["call_measure", "call_metrics", "run_sql"], has_measures=True, network="none"
    )
    assert "Results from call_measure, call_metrics, and run_sql are preloaded" in (
        description
    )
    description = run_python_description(
        ["run_sql"], has_measures=False, network="none"
    )
    assert "Results from run_sql are preloaded" in description


def test_measure_sources_are_described_only_when_there_are_measures() -> None:
    with_measures = run_python_description(
        ["run_sql"], has_measures=True, network="none"
    )
    without = run_python_description(["run_sql"], has_measures=False, network="none")
    assert "inspect.getsource()" in with_measures
    assert "inspect.getsource()" not in without


@pytest.mark.parametrize(
    ("network", "can_install", "rule"),
    [
        ("none", True, "- The session has no network access."),
        ("full", True, "`sys.executable -m pip install --target`"),
        ("full", False, "only packages that are already installed can be imported"),
    ],
)
def test_the_network_rule_says_what_the_session_can_reach(
    network: Any, can_install: bool, rule: str
) -> None:
    description = run_python_description(
        ["run_sql"], has_measures=False, network=network, can_install=can_install
    )
    assert rule in description.split("\n\nRules:")[1]


def test_the_plot_rule_says_whether_the_session_can_draw() -> None:
    def rules(can_plot: bool) -> str:
        return run_python_description(
            ["run_sql"], has_measures=False, network="none", can_plot=can_plot
        ).split("\n\nRules:")[1]

    assert "at most one matplotlib figure per call" in rules(True)
    assert "the session cannot draw plots" in rules(False)


def test_a_module_the_isolated_session_cannot_see_is_not_importable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    assert session_can_import("pytest")
    assert not session_can_import("no_such_module_for_commons")
    # On PYTHONPATH and so on this process's path, but -I ignores both.
    (tmp_path / "only_on_pythonpath.py").write_text("")
    monkeypatch.setenv("PYTHONPATH", str(tmp_path))
    monkeypatch.syspath_prepend(str(tmp_path))
    assert importlib.util.find_spec("only_on_pythonpath") is not None
    assert not session_can_import("only_on_pythonpath")


# ---- the result -------------------------------------------------------------


def test_a_result_shows_what_was_printed_and_the_value() -> None:
    result = run_python_result(
        "print('hi')\n1 + 1", Result(id="c1", value=2, stdout="hi\n", stderr="warn\n")
    )
    assert result.value == "hi\nwarn\n2"
    assert result.extra is not None
    assert result.extra[TAG_EXTRA_KEY] == Tag.B
    assert display(result)["title"] == "Analyzed data"
    assert display(result)["open"] is False


def test_a_call_that_shows_nothing_says_so() -> None:
    assert run_python_result("x = 1", Result(id="c1")).value == NO_OUTPUT


def test_a_frame_value_is_a_table_and_an_opaque_value_is_its_repr() -> None:
    table = run_python_result("df", Result(id="c1", value=frame())).value
    assert "| revenue |" in table
    opaque = OpaqueValue(type_name="Connection", text="<Connection at 0x1>")
    assert run_python_result("con", Result(id="c1", value=opaque)).value == (
        "<Connection at 0x1>"
    )


def test_an_error_shows_the_traceback_and_a_failure_its_message() -> None:
    error = Error(
        id="c1",
        message="NameError: name 'y' is not defined",
        traceback="Traceback...\nNameError",
    )
    assert run_python_result("y", error).value == "Traceback...\nNameError"
    failure = run_python_result("1", Failure(message="the Python session crashed."))
    assert failure.value == "Error: the Python session crashed."
    assert failure.extra is not None
    assert failure.extra[TAG_EXTRA_KEY] == Tag.B


def test_plots_reach_the_model_as_images_and_the_reader_at_their_size() -> None:
    result = run_python_result(
        "fig", Result(id="c1", stdout="drawn\n", plots=(plot(),))
    )
    parts = result.value
    assert isinstance(parts, list)
    assert isinstance(parts[0], ContentText) and parts[0].text == "drawn"
    image = parts[1]
    assert isinstance(image, ContentImageInline)
    assert base64.b64decode(image.data) == plot().png
    assert "already visible to the user" in parts[-1].text
    shown = display(result)
    assert shown["open"] is True
    html = str(shown["html"])
    assert 'class="commons-run-details"' in html
    assert base64.b64encode(plot().display_png).decode() in html
    assert 'width="400"' in html and 'height="300"' in html


def test_the_display_shows_the_code_and_its_output_escaped() -> None:
    html = str(
        display(run_python_result("'<b>'", Result(id="c1", value="<b>")))["html"]
    )
    assert 'class="commons-run-code"' in html
    assert "#&gt; &#x27;&lt;b&gt;&#x27;" in html or "#&gt; '&lt;b&gt;'" in html
    assert "<b>" not in html


# ---- highlighting -----------------------------------------------------------


def test_highlighting_marks_tokens_with_the_stylesheets_classes() -> None:
    out = highlight_python("def f(x):\n    return len('a') + 1  # note\n")
    assert '<span class="hl kwa">def</span>' in out
    assert '<span class="hl kwd">len</span>' in out
    assert '<span class="hl sng">&#x27;a&#x27;</span>' in out
    assert '<span class="hl num">1</span>' in out
    assert '<span class="hl com"># note</span>' in out


def test_text_that_does_not_tokenize_is_escaped_plainly() -> None:
    assert highlight_python("'''<open") == "&#x27;&#x27;&#x27;&lt;open"


# ---- through an agent -------------------------------------------------------


def test_an_agent_registers_run_python_with_the_measure_source_note() -> None:
    agent = Commons(
        scripted_chat(),
        {"sales": data_source(sales=frame())},
        semantic_layer(total_revenue),
    )
    description = run_python_tool(agent).schema["function"]["description"]
    assert "inspect.getsource()" in description
    assert "Results from call_measure and run_sql are preloaded" in description


def test_chat_runs_code_against_a_preloaded_handle() -> None:
    agent = Commons(
        scripted_chat(
            [
                [
                    ContentToolRequest(
                        id="q", name="run_sql", arguments={"sql": "SELECT * FROM sales"}
                    )
                ],
                tool_request(code="sum(row['revenue'] for row in r1)"),
                text("Done."),
            ]
        ),
        data_source(sales=frame()),
    )
    agent.chat("Total revenue?", echo="none")
    run = tool_results(agent)[-1]
    assert run.value.startswith("1700.0")
    # The async tool is back in place for stream_async.
    assert run_python_tool(agent)._is_async


async def test_stream_async_keeps_session_state_and_reads_measure_sources() -> None:
    agent = Commons(
        scripted_chat(
            [
                tool_request(code="x = 41"),
                tool_request(
                    code="import inspect\nprint(inspect.getsource(total_revenue))\nx + 1"
                ),
                text("Done."),
            ]
        ),
        {"sales": data_source(sales=frame())},
        semantic_layer(total_revenue),
    )
    stream = await agent.stream_async("Go.")
    [chunk async for chunk in stream]
    run = tool_results(agent)[-1]
    assert "def total_revenue(sales" in run.value
    assert "\n42" in run.value


@pytest.mark.skipif(
    importlib.util.find_spec("matplotlib") is None, reason="needs matplotlib"
)
async def test_a_plot_reaches_the_model_as_an_image() -> None:
    provider_chat = scripted_chat(
        [
            tool_request(code="import matplotlib.pyplot as plt\nplt.plot([1, 2, 3])"),
            text("Done."),
        ]
    )
    agent = Commons(provider_chat, data_source(sales=frame()))
    stream = await agent.stream_async("Plot it.")
    [chunk async for chunk in stream]
    run = tool_results(agent)[-1]
    assert any(isinstance(part, ContentImageInline) for part in run.value)
    # chatlas moves the image out of the tool result for the provider.
    last_request = agent.provider.requests[-1]  # type: ignore[attr-defined]
    sent = [content for turn in last_request for content in turn.contents]
    assert any(isinstance(content, ContentImageInline) for content in sent)

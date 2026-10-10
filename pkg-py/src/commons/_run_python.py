"""The `run_python` tool: model-written Python run in the agent's sandboxed session.

`pkg-r/R/run-r.R` builds R's `run_r`, and the two tools describe themselves
and shape their results the same way, each in its own language's idiom.

The agent registers the async tool, which awaits the session without blocking
the caller's event loop. chatlas refuses a synchronous `chat()` while any async
tool is registered, so `Commons.chat()` swaps in the sync tool for the call.
"""

from __future__ import annotations

import base64
import functools
import html
import io
import keyword
import subprocess
import sys
import tempfile
import tokenize
from collections.abc import Sequence
from typing import Any

from chatlas import ContentToolResult, Tool
from chatlas.types import ContentImageInline, ContentText
from htmltools import HTML, Tag, div, tags

from ._citations import tool_result
from ._display import CODE_ANALYSIS, visible_result_note
from ._execution._backend import Network
from ._execution._driver import Failure
from ._execution._env import worker_env
from ._execution._protocol import Error, OpaqueValue, Plot, Result, Text
from ._execution._sandbox import needs_single_thread
from ._execution._thread import WorkerThread
from ._frames import describe_frame, is_frame
from ._prompt import EXECUTION_TOOL
from ._provenance import Tag as ProvenanceTag
from ._rows import frame_rows, rows_to_markdown
from ._tools import ToolContext

__all__ = [
    "HANDLE_TOOLS",
    "run_python_description",
    "run_python_result",
    "run_python_tools",
]

# The tools whose results are stored as handles, in the order the
# description names them.
HANDLE_TOOLS = ("call_measure", "call_metrics", "run_sql")

NO_OUTPUT = "(The code ran but produced no output.)"

# How long to wait for the session's interpreter to say what it can import.
PROBE_TIMEOUT = 10.0


def run_python_description(
    tool_names: Sequence[str],
    *,
    has_measures: bool,
    network: Network,
    can_plot: bool | None = None,
    can_install: bool | None = None,
) -> str:
    """What `run_python` tells the model it is for.

    ``tool_names`` are the agent's other registered tools; the preloaded
    handles are named after whichever of them store results. ``can_plot``
    and ``can_install`` say whether the session can import matplotlib and
    pip, and default to asking the interpreter the session runs.
    """
    if can_plot is None:
        can_plot = session_can_import("matplotlib")
    if can_install is None:
        can_install = session_can_import("pip")
    handle_tools = [name for name in HANDLE_TOOLS if name in tool_names]
    parts = [
        (
            "Run Python code in your sandboxed Python session to analyze results or "
            "render plots. Python code and textual output are visible only to you; "
            "rendered plots are also shown to the user."
        ),
        (
            "The user cannot access or interact with this session. Never direct them "
            "to run code or inspect its variables or files; perform follow-up "
            "analysis yourself and report the result in your response."
        ),
        (
            "Your session persists across calls: variables you assign and modules "
            "you import remain available."
        ),
    ]
    if handle_tools:
        parts.append(
            f"Results from {_listed(handle_tools)} are preloaded as variables "
            "(r1, r2, ...)."
        )
    if has_measures:
        parts.append(
            "Measure definitions and their helper functions are predefined under "
            "their own names: call inspect.getsource() on a measure to read its "
            "source. These are source-only copies without their original "
            "environment or database connections, so treat them as reference "
            "material; to compute a measure, use call_measure."
        )
    rules = [
        "Work incrementally: each call should do one small, well-defined task.",
        (
            "Follow PEP 8: put separate statements on separate lines and wrap long "
            "calls for readability."
        ),
        (
            "Create at most one matplotlib figure per call. Draw it with pyplot "
            "and do not call savefig, since a saved file reaches neither you nor "
            "the user. The figure appears where you call plt.show() or "
            "fig.show(), or after the call's text if you call neither."
            if can_plot
            else "matplotlib is not installed, so the session cannot draw plots."
        ),
        (
            "Do not use this tool to talk to the user; explanations belong in your "
            "reply."
        ),
        (
            "Return results by ending with an expression (`df`, not `print(df)`) "
            "and prefer brief summaries (df.head(), df.describe()) over large "
            "outputs."
        ),
        "The session can only write to its own temporary directory.",
    ]
    if network == "none":
        rules.append("The session has no network access.")
    elif can_install:
        rules.append(
            "The session has network access. To use a package that is not "
            "installed, run `sys.executable -m pip install --target` with the "
            "temporary directory through subprocess, then add that directory "
            "to sys.path."
        )
    else:
        rules.append(
            "The session has network access, but only packages that are "
            "already installed can be imported."
        )
    return " ".join(parts) + "\n\nRules:" + "".join(f"\n- {rule}" for rule in rules)


@functools.cache
def session_can_import(module: str) -> bool:
    """Whether the session's interpreter can find the top-level ``module``.

    The session runs this interpreter under ``-I``, which leaves out the user
    site directory, ``PYTHONPATH``, and the current directory, so the answer
    comes from asking that interpreter the same way, with the session's
    environment and an empty scratch directory. It is cached, since the
    interpreter's packages do not change while it runs.
    """
    probe = "import importlib.util, sys; sys.exit(importlib.util.find_spec(sys.argv[1]) is None)"
    try:
        with tempfile.TemporaryDirectory(prefix="commons-probe-") as scratch:
            completed = subprocess.run(
                [sys.executable, "-I", "-c", probe, module],
                capture_output=True,
                cwd=scratch,
                env=worker_env(scratch, single_thread=needs_single_thread()),
                timeout=PROBE_TIMEOUT,
                check=False,
            )
    except (OSError, subprocess.SubprocessError):
        return False
    return completed.returncode == 0


def _listed(names: Sequence[str]) -> str:
    if len(names) <= 2:
        return " and ".join(names)
    return f"{', '.join(names[:-1])}, and {names[-1]}"


def run_python_tools(
    runner: WorkerThread, context: ToolContext, description: str, network: Network
) -> tuple[Tool, Tool]:
    """The async tool the agent registers, and the sync one `chat()` swaps in."""

    def finish(code: str, reply: Result | Error | Failure) -> ContentToolResult:
        result = run_python_result(code, reply)
        if context.citation_request is None:
            return result
        return context.citation_request.add_request(result)

    async def run_python(code: str) -> ContentToolResult:
        return finish(code, await runner.run(code, context.handles))

    def run_python_sync(code: str) -> ContentToolResult:
        return finish(code, runner.run_sync(code, context.handles))

    parameters = {
        "type": "object",
        "properties": {
            "code": {"type": "string", "description": "The Python code to run."}
        },
        "required": ["code"],
        "additionalProperties": False,
    }
    annotations: Any = {
        "title": CODE_ANALYSIS.running,
        "readOnlyHint": False,
        "openWorldHint": network == "full",
    }

    def build(func: Any) -> Tool:
        return Tool(
            func=func,
            name=EXECUTION_TOOL,
            description=description,
            parameters=parameters,
            annotations=annotations,
        )

    return build(run_python), build(run_python_sync)


def run_python_result(code: str, reply: Result | Error | Failure) -> ContentToolResult:
    """The tool result for one call: the model's view and the reader's.

    The model gets what the call wrote, with each plot as an image in the
    place it was drawn. The reader gets the code with its output, and the
    plots at their size.
    """
    runs = _runs(reply)
    plots = [run for run in runs if isinstance(run, Plot)]
    return tool_result(
        _model_value(runs),
        ProvenanceTag.B,
        title=CODE_ANALYSIS.settled,
        html=_display_html(code, runs),
        open=bool(plots),
    )


def _runs(reply: Result | Error | Failure) -> list[str | Plot]:
    """The reply's output in order, with adjacent text joined into one run.

    Streams are joined as written, so a line split across two writes stays
    one line. The value a call ended on, or its error, starts a line of its
    own after everything the call wrote.
    """
    if isinstance(reply, Failure):
        return [f"Error: {reply.message}"]
    if isinstance(reply, Error):
        last = reply.traceback.strip() or f"Error: {reply.message}"
    else:
        last = _value_text(reply.value)
    runs: list[str | Plot] = []
    text = ""
    for segment in reply.output:
        if isinstance(segment, Text):
            text += segment.text
            continue
        if text.strip("\n"):
            runs.append(text.rstrip("\n"))
        text = ""
        runs.append(segment)
    if last:
        text += ("\n" if text and not text.endswith("\n") else "") + last
    if text.strip("\n"):
        runs.append(text.rstrip("\n"))
    return runs


def _value_text(value: Any) -> str:
    """The value a call ended on, as a REPL would show it; empty for None."""
    if value is None:
        return ""
    if isinstance(value, OpaqueValue):
        return value.text
    if is_frame(value):
        rows = frame_rows(value)
        return rows_to_markdown(rows) if rows is not None else describe_frame(value)
    return repr(value)


def _model_value(runs: list[str | Plot]) -> Any:
    if not any(isinstance(run, Plot) for run in runs):
        return "\n".join(run for run in runs if isinstance(run, str)) or NO_OUTPUT
    parts: list[Any] = [
        ContentImageInline(
            image_content_type="image/png",
            data=base64.b64encode(run.png).decode("ascii"),
        )
        if isinstance(run, Plot)
        else ContentText(text=run)
        for run in runs
    ]
    parts.append(ContentText(text=visible_result_note("plot")))
    return parts


def _display_html(code: str, runs: list[str | Plot]) -> Tag:
    output = [
        f"#> {line}" for run in runs if isinstance(run, str) for line in run.split("\n")
    ]
    plots = [run for run in runs if isinstance(run, Plot)]
    block: Tag = tags.pre(
        tags.code(
            HTML(highlight_python("\n".join([code, *output]))),
            class_="language-python",
        ),
        class_="commons-run-code",
    )
    if plots:
        block = tags.details(
            tags.summary("Details"), block, class_="commons-run-details"
        )
    images = [
        tags.img(
            class_="commons-run-plot",
            src="data:image/png;base64,"
            + base64.b64encode(plot.display_png).decode("ascii"),
            alt="Plot produced by Python code",
            width=str(plot.width),
            height=str(plot.height),
        )
        for plot in plots
    ]
    return div(block, *images, class_="commons-run-display")


# The highlight classes the shared stylesheet styles, by token kind.
_COMMENT, _KEYWORD, _CALL, _NUMBER, _STRING = "com", "kwa", "kwd", "num", "sng"
_STRING_TOKENS = {
    name
    for name in ("STRING", "FSTRING_START", "FSTRING_MIDDLE", "FSTRING_END")
    if hasattr(tokenize, name)
}


def highlight_python(source: str) -> str:
    """``source`` as escaped HTML, with its tokens wrapped for the stylesheet.

    Text that does not tokenize as Python is escaped and left plain.
    """
    lines = source.splitlines(keepends=True)
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line))

    def offset(position: tuple[int, int]) -> int:
        row, column = position
        return starts[row - 1] + column if row <= len(lines) else len(source)

    spans: list[tuple[int, int, str]] = []
    try:
        tokens = list(tokenize.generate_tokens(io.StringIO(source).readline))
    except (tokenize.TokenError, SyntaxError):
        return html.escape(source)
    for index, token in enumerate(tokens):
        kind = _token_class(
            token, tokens[index + 1] if index + 1 < len(tokens) else None
        )
        if kind is not None:
            spans.append((offset(token.start), offset(token.end), kind))

    out: list[str] = []
    cursor = 0
    for start, end, kind in spans:
        if start < cursor:
            continue
        out.append(html.escape(source[cursor:start]))
        out.append(f'<span class="hl {kind}">{html.escape(source[start:end])}</span>')
        cursor = end
    out.append(html.escape(source[cursor:]))
    return "".join(out)


def _token_class(
    token: tokenize.TokenInfo, following: tokenize.TokenInfo | None
) -> str | None:
    name = tokenize.tok_name[token.type]
    if token.type == tokenize.COMMENT:
        return _COMMENT
    if token.type == tokenize.NUMBER:
        return _NUMBER
    if name in _STRING_TOKENS:
        return _STRING
    if token.type == tokenize.NAME:
        if keyword.iskeyword(token.string):
            return _KEYWORD
        if following is not None and following.string == "(":
            return _CALL
    return None

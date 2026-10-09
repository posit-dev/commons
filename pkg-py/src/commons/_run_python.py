"""The `run_python` tool: model-written Python run in the agent's sandboxed session.

`pkg-r/R/run-r.R` builds R's `run_r`, and the two tools describe themselves
and shape their results the same way, each in its own language's idiom.

The agent registers the async tool, which awaits the session without blocking
the caller's event loop. chatlas refuses a synchronous `chat()` while any async
tool is registered, so `Commons.chat()` swaps in the sync tool for the call.
"""

from __future__ import annotations

import base64
import html
import importlib.util
import io
import keyword
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
from ._execution._protocol import Error, OpaqueValue, Plot, Result
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


def run_python_description(
    tool_names: Sequence[str],
    *,
    has_measures: bool,
    network: Network,
    can_install: bool | None = None,
) -> str:
    """What `run_python` tells the model it is for.

    ``tool_names`` are the agent's other registered tools; the preloaded
    handles are named after whichever of them store results. ``can_install``
    says whether the session's interpreter has pip, and defaults to asking
    this one, which is the interpreter the session runs.
    """
    if can_install is None:
        can_install = importlib.util.find_spec("pip") is not None
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
            "Create at most one matplotlib figure per call and leave it open rather "
            "than saving it."
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

    The model gets the text the call produced and each plot as an image.
    The reader gets the code with its output, and the plots at their size.
    """
    plots: tuple[Plot, ...] = ()
    if isinstance(reply, Failure):
        texts = [f"Error: {reply.message}"]
    elif isinstance(reply, Error):
        texts = [reply.traceback.strip() or f"Error: {reply.message}"]
        plots = reply.plots
    else:
        texts = [
            text
            for text in (
                reply.stdout.rstrip("\n"),
                reply.stderr.rstrip("\n"),
                _value_text(reply.value),
            )
            if text
        ]
        plots = reply.plots
    return tool_result(
        _model_value(texts, plots),
        ProvenanceTag.B,
        title=CODE_ANALYSIS.settled,
        html=_display_html(code, texts, plots),
        open=bool(plots),
    )


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


def _model_value(texts: list[str], plots: tuple[Plot, ...]) -> Any:
    text = "\n".join(texts)
    if not plots:
        return text or NO_OUTPUT
    parts: list[Any] = [ContentText(text=text)] if text else []
    parts.extend(
        ContentImageInline(
            image_content_type="image/png",
            data=base64.b64encode(plot.png).decode("ascii"),
        )
        for plot in plots
    )
    parts.append(ContentText(text=visible_result_note("plot")))
    return parts


def _display_html(code: str, texts: list[str], plots: tuple[Plot, ...]) -> Tag:
    output = [f"#> {line}" for text in texts for line in text.split("\n")]
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

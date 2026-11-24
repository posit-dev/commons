"""Write the trace committed under tests/shared/traces/python/.

The conversations run through real logging agents over a scripted model, so
the spans are the ones a live model would produce for the same turns. A
tracer provider can be installed once per process, so run this in its own.
To regenerate the committed trace, from the repository root:

    rm -f tests/shared/traces/python/trace-1.jsonl
    cd pkg-py && uv run --extra tracing python -m tests._trace_fixture ../tests/shared/traces/python && cd .. && scripts/sync-shared.sh

``recipe()`` reads the get-started recipe that writes trace files locally.
"""

from __future__ import annotations

import asyncio
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

import pandas as pd
from chatlas import ContentToolRequest
from chatlas.types import ContentText

from commons import context_layer, data_source

from ._agents import collect, logging_agent_over
from ._provider import text

TRACE_FILE = "trace-1.jsonl"
GET_STARTED = Path(__file__).parents[1] / "docs" / "01-get-started.qmd"
RECIPE_HEADING = "## Logging conversations"

DOCUMENTS = [
    "Orders are one row per placed order.",
    "A customer is an account that has placed at least one order.",
]
QUERY_TOOL = "run_sql"


def query() -> list[Any]:
    return [
        ContentToolRequest(
            id="call-1",
            name=QUERY_TOOL,
            arguments={"sql": "SELECT count(*) AS n FROM orders"},
        )
    ]


def cited(answer: str, quote: str) -> list[Any]:
    return [
        ContentText(text=f"{answer}\n\n<citation>\n\nWhy.\n\n> {quote}\n\n</citation>")
    ]


def recipe() -> str:
    """The Python block in the get-started section on logging conversations."""
    text = GET_STARTED.read_text(encoding="utf-8")
    section = text.split(RECIPE_HEADING, 1)[1].split("\n## ", 1)[0]
    match = re.search(r"```python\n(.*?)```", section, re.DOTALL)
    assert match, f"no Python block under {RECIPE_HEADING!r}"
    return match.group(1)


def source() -> Any:
    return data_source(
        orders=pd.DataFrame({"id": [1, 2, 3], "total": [10.0, 20.0, 30.0]}),
        customers=pd.DataFrame({"id": [1, 2], "name": ["Ada", "Bo"]}),
    )


def documents(directory: Path) -> Any:
    paths = []
    for position, body in enumerate(DOCUMENTS):
        path = directory / f"doc{position}.md"
        path.write_text(f"# Term\n\n{body}", encoding="utf-8")
        paths.append(path)
    return context_layer(paths)


async def converse(layer: Any) -> None:
    # Each host conversation id stands in for the one shinychat sets.
    first = logging_agent_over(
        source(),
        [
            query(),
            cited("There are three orders.", DOCUMENTS[0]),
            cited("Each order is one row.", "Orders are counted twice."),
        ],
        conversation_id="first",
        context_layer=layer,
    )
    await collect(first, "How many orders are there?")
    await collect(first, "Can an order appear twice?")

    second = logging_agent_over(
        source(),
        [text("Hello. Ask me about orders or customers.")],
        conversation_id="second",
        context_layer=layer,
    )
    await collect(second, "Hello")


def write_trace(directory: Path) -> Path:
    """Run the scripted conversations with spans exported into `directory`."""
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.json.file import FileSpanExporter
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor

    directory.mkdir(parents=True, exist_ok=True)
    existing = sorted(directory.glob("*.jsonl"))
    if existing:
        raise FileExistsError(f"{directory} already has a trace: {existing[0].name}")
    trace_file = directory / TRACE_FILE

    provider = TracerProvider()
    provider.add_span_processor(
        SimpleSpanProcessor(FileSpanExporter(path=str(trace_file)))
    )
    trace.set_tracer_provider(provider)

    completed = False
    try:
        with tempfile.TemporaryDirectory() as docs:
            asyncio.run(converse(documents(Path(docs))))
        completed = True
    finally:
        provider.shutdown()
        # A partial trace would block the next run.
        if not completed:
            trace_file.unlink(missing_ok=True)
    return trace_file


if __name__ == "__main__":
    print(write_trace(Path(sys.argv[1])))

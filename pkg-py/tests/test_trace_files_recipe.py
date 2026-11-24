"""The documented recipe for writing trace files locally produces trace files."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from ._fresh_interpreter import run_in_fresh_interpreter

pytest.importorskip("opentelemetry.sdk")
pytest.importorskip("opentelemetry.exporter.otlp.json.file")

GET_STARTED = Path(__file__).parents[1] / "docs" / "01-get-started.qmd"
HEADING = "## Logging conversations"


def recipe() -> str:
    text = GET_STARTED.read_text()
    section = text.split(HEADING, 1)[1].split("\n## ", 1)[0]
    match = re.search(r"```python\n(.*?)```", section, re.DOTALL)
    assert match, f"no Python block under {HEADING!r}"
    return match.group(1)


def test_the_recipe_writes_a_trace_file(tmp_path: Path) -> None:
    script = (
        f"import os; os.chdir({str(tmp_path)!r})\n"
        + recipe()
        + """
from commons._tracing import commons_span

with commons_span("commons_recipe_check"):
    pass
provider.shutdown()
"""
    )
    run_in_fresh_interpreter(script)

    lines = (tmp_path / "traces" / "trace-1.jsonl").read_text().splitlines()
    assert any("resourceSpans" in json.loads(line) for line in lines)

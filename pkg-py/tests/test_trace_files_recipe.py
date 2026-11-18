"""The documented recipe for writing trace files locally produces trace files."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ._fresh_interpreter import run_in_fresh_interpreter
from ._trace_fixture import recipe

pytest.importorskip("opentelemetry.sdk")
pytest.importorskip("opentelemetry.exporter.otlp.json.file")


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

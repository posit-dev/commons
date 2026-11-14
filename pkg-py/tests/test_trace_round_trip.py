"""The trace the Python agent writes, which the R suite reads with trajectory_read()."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import pytest

from ._fresh_interpreter import run_in_fresh_interpreter
from ._shared import SHARED_DIR, load_shared_fixture
from ._trace_fixture import TRACE_FILE

COMMITTED = SHARED_DIR / "traces" / "python" / "trace-1.jsonl"
FILE_NAMING = load_shared_fixture("traces")["file_naming"]["cases"]
GET_STARTED = Path(__file__).parents[1] / "docs" / "01-get-started.qmd"

_IDS = ("traceId", "spanId", "parentSpanId")
_TIMESTAMPS = ("startTimeUnixNano", "endTimeUnixNano")
_CONVERSATION = "gen_ai.conversation.id"
# The system prompt states the day it was written.
_DATE = re.compile(r"Today's date is \d{4}-\d{2}-\d{2}\.")


def normalized(path: Path) -> list[dict[str, Any]]:
    """The spans in file order, with what varies between runs replaced.

    Ids and conversation ids become the order each first appears, and
    timestamps, resource attributes, the scope version, and the prompt's date
    are dropped.
    """
    ordinals: dict[str, str] = {}

    def ordinal(value: str) -> str:
        return ordinals.setdefault(value, f"#{len(ordinals) + 1}")

    spans = []
    for line in path.read_text(encoding="utf-8").splitlines():
        for resource in json.loads(line)["resourceSpans"]:
            for scope_spans in resource["scopeSpans"]:
                scope = {
                    k: v for k, v in scope_spans["scope"].items() if k != "version"
                }
                for span in scope_spans["spans"]:
                    span = {k: v for k, v in span.items() if k not in _TIMESTAMPS}
                    for key in _IDS:
                        if span.get(key):
                            span[key] = ordinal(span[key])
                    for attribute in span.get("attributes", []):
                        value = attribute["value"]
                        if "stringValue" not in value:
                            continue
                        if attribute["key"] == _CONVERSATION:
                            value["stringValue"] = ordinal(value["stringValue"])
                        else:
                            value["stringValue"] = _DATE.sub(
                                "Today's date is <date>.", value["stringValue"]
                            )
                    spans.append({"scope": scope, **span})
    return spans


def test_the_agent_still_writes_the_committed_trace(tmp_path: Path) -> None:
    pytest.importorskip("opentelemetry.exporter.otlp.json.file")
    written = run_in_fresh_interpreter(
        "from pathlib import Path; from tests._trace_fixture import write_trace; "
        f"print(write_trace(Path({str(tmp_path)!r})))"
    )
    committed = normalized(COMMITTED)
    assert committed
    assert normalized(Path(written.strip())) == committed, (
        "The agent no longer writes the committed trace. If the change is intended, "
        "regenerate it: cd pkg-py && rm ../tests/shared/traces/python/trace-1.jsonl && "
        "uv run python -m tests._trace_fixture ../tests/shared/traces/python, "
        "then run scripts/sync-shared.sh and the R suite."
    )


def recipe_trace_file() -> str:
    section = GET_STARTED.read_text().split("## Logging conversations", 1)[1]
    match = re.search(r'^trace_file = .*"([^"/]+)"$', section, re.MULTILINE)
    assert match, "the recipe names no trace file"
    return match.group(1)


def test_the_shared_file_naming_cases_are_present() -> None:
    assert FILE_NAMING


@pytest.mark.parametrize(
    "name", [TRACE_FILE, recipe_trace_file()], ids=["write_trace", "recipe"]
)
def test_trace_files_are_written_under_a_name_a_reader_takes(name: str) -> None:
    taken = {case["file"] for case in FILE_NAMING if case["read"]}
    assert name in taken

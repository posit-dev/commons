"""The Python agent keeps writing the trace committed under tests/shared/traces/python/.

The R suite reads that committed trace with trajectory_read(), so the check
that R reads what Python writes is only as current as the trace. These tests
fail when the agent's spans drift from it, and when a writer names its trace
file something a reader skips.
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from ._fresh_interpreter import run_in_fresh_interpreter
from ._shared import SHARED_DIR, load_shared_fixture
from ._trace_fixture import TRACE_FILE, recipe

COMMITTED = SHARED_DIR / "traces" / "python" / "trace-1.jsonl"
FILE_NAMING = load_shared_fixture("traces")["file_naming"]["cases"]

_IDS = {"trace": "traceId", "span": "spanId", "parent": "parentSpanId"}
# OTLP's status code for a span that ended with an error.
_ERROR = 2
_CONVERSATION = "gen_ai.conversation.id"
# The system prompt and tool descriptions change on their own schedule.
_INSTRUCTIONS = "gen_ai.system_instructions"
_TOOL_DESCRIPTION = "gen_ai.tool.description"
_PROSE = "<prose>"


def _masked_instructions(value: str) -> str:
    """The system instructions with each part's text masked and its shape kept."""
    parts = json.loads(value)
    if isinstance(parts, list):
        for part in parts:
            if isinstance(part, dict) and isinstance(part.get("content"), str):
                part["content"] = _PROSE
    return json.dumps(parts)


def normalized(path: Path) -> list[dict[str, Any]]:
    """The spans in file order, keeping only the fields commons and the readers use.

    Each span keeps its scope and span names, its ids, its attributes, and
    whether it records an error. Other span fields, such as flags and kind,
    belong to the SDK and are not compared. Ids and conversation ids become
    the order each first appears, and the text of the system instructions and
    tool descriptions becomes a placeholder. The system instructions keep
    their structure, so a change to their part count or part types still
    fails. Span names, attribute keys, and message content are compared as
    written.
    """
    ordinals: dict[str, str] = {}

    def ordinal(value: str) -> str:
        return ordinals.setdefault(value, f"#{len(ordinals) + 1}")

    spans = []
    for line in path.read_text(encoding="utf-8").splitlines():
        for resource in json.loads(line)["resourceSpans"]:
            for scope_spans in resource["scopeSpans"]:
                scope = scope_spans["scope"]["name"]
                for span in scope_spans["spans"]:
                    ids = {
                        name: ordinal(span[key])
                        for name, key in _IDS.items()
                        if span.get(key)
                    }
                    attributes = span.get("attributes", [])
                    for attribute in attributes:
                        value = attribute["value"]
                        if "stringValue" not in value:
                            continue
                        if attribute["key"] == _CONVERSATION:
                            value["stringValue"] = ordinal(value["stringValue"])
                        elif attribute["key"] == _INSTRUCTIONS:
                            value["stringValue"] = _masked_instructions(
                                value["stringValue"]
                            )
                        elif attribute["key"] == _TOOL_DESCRIPTION:
                            value["stringValue"] = _PROSE
                    spans.append(
                        {
                            "scope": scope,
                            "name": span["name"],
                            "ids": ids,
                            "attributes": attributes,
                            "error": span.get("status", {}).get("code") == _ERROR,
                        }
                    )
    return spans


def test_the_trace_comparison_ignores_sdk_fields_and_keeps_an_error(
    tmp_path: Path,
) -> None:
    def normalized_span(**fields: Any) -> list[dict[str, Any]]:
        span = {"traceId": "t", "spanId": "s", "name": "x", **fields}
        envelope = {
            "resourceSpans": [
                {"scopeSpans": [{"scope": {"name": "commons"}, "spans": [span]}]}
            ]
        }
        path = tmp_path / "trace.jsonl"
        path.write_text(json.dumps(envelope) + "\n", encoding="utf-8")
        return normalized(path)

    plain = normalized_span(flags=256, kind=1, status={})
    assert normalized_span(flags=768, kind=3, status={"code": 1}) == plain
    assert normalized_span(flags=256, kind=1, status={"code": 2}) != plain


def test_the_agent_still_writes_the_committed_trace(tmp_path: Path) -> None:
    pytest.importorskip("opentelemetry.exporter.otlp.json.file")
    run_in_fresh_interpreter(
        "from pathlib import Path; from tests._trace_fixture import write_trace; "
        f"write_trace(Path({str(tmp_path)!r}))"
    )
    committed = normalized(COMMITTED)
    assert committed
    assert normalized(tmp_path / TRACE_FILE) == committed, (
        "The agent no longer writes the committed trace. If the change is intended, "
        "regenerate it from the repository root: "
        "rm -f tests/shared/traces/python/trace-1.jsonl && cd pkg-py && "
        "uv run --extra tracing python -m tests._trace_fixture "
        "../tests/shared/traces/python && cd .. && scripts/sync-shared.sh, "
        "then run the R suite."
    )


def recipe_trace_file() -> str:
    match = re.search(r'^trace_file = .*"([^"/]+)"$', recipe(), re.MULTILINE)
    assert match, "the recipe names no trace file"
    return match.group(1)


def test_the_shared_file_naming_cases_are_present() -> None:
    assert FILE_NAMING


@pytest.mark.parametrize(
    "name", [lambda: TRACE_FILE, recipe_trace_file], ids=["write_trace", "recipe"]
)
def test_trace_files_are_written_under_a_name_a_reader_takes(
    name: Callable[[], str],
) -> None:
    taken = {case["file"] for case in FILE_NAMING if case["read"]}
    assert name() in taken

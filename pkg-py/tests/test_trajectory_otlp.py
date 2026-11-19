"""Tests for reading OTLP trace lines into spans.

The cases live in ``tests/shared/trajectories/otlp.json``, and the R suite runs
the same cases, so a case belongs in the fixture rather than here. This module
adds only what the fixture cannot pin.
"""

import json
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any

import pytest

from commons._trajectory import trajectory_read
from commons._trajectory._otlp import (
    EXPORTER_FILE_VAR,
    TRACES_DIR_VAR,
    local_traces_dir,
    otlp_attribute_value,
    parse_otlp_lines,
    read_local_spans,
)
from tests._shared import SHARED_DIR, load_shared_fixture

OTLP = load_shared_fixture("trajectories/otlp")


@pytest.fixture(autouse=True)
def _clean_trace_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(EXPORTER_FILE_VAR, raising=False)
    monkeypatch.delenv(TRACES_DIR_VAR, raising=False)


def _write_span(path: Path, span_id: str) -> None:
    envelope = {
        "resourceSpans": [
            {"scopeSpans": [{"spans": [{"traceId": "t1", "spanId": span_id}]}]}
        ]
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(envelope) + "\n", encoding="utf-8")


def _line(line: object) -> str:
    return line if isinstance(line, str) else json.dumps(line)


def test_the_fixture_has_cases() -> None:
    assert OTLP["lines"]["cases"]
    assert OTLP["attribute_values"]["cases"]


@pytest.mark.parametrize("case", OTLP["lines"]["cases"], ids=lambda case: case["name"])
def test_lines_parse_as_the_shared_fixture_pins(case: dict[str, Any]) -> None:
    spans = parse_otlp_lines(_line(line) for line in case["lines"])

    assert len(spans) == len(case["spans"])
    for span, expected in zip(spans, case["spans"], strict=True):
        assert span.trace_id == expected["trace_id"]
        assert span.span_id == expected["span_id"]
        assert span.parent_span_id == expected["parent_span_id"]
        assert span.name == expected["name"]
        if "start_time_unix_nano" in expected:
            assert span.start_time_unix_nano == int(expected["start_time_unix_nano"])
        if "end_time_unix_nano" in expected:
            assert span.end_time_unix_nano == int(expected["end_time_unix_nano"])
        assert span.attributes == expected["attributes"]


@pytest.mark.parametrize(
    "case", OTLP["attribute_values"]["cases"], ids=lambda case: case["name"]
)
def test_attribute_values_decode_as_the_shared_fixture_pins(
    case: dict[str, Any],
) -> None:
    assert otlp_attribute_value(case["value"]) == case["expected"]


def test_an_absent_timestamp_reads_as_zero() -> None:
    (span,) = parse_otlp_lines(['{"resourceSpans":[{"scopeSpans":[{"spans":[{}]}]}]}'])
    assert (span.start_time_unix_nano, span.end_time_unix_nano) == (0, 0)


FILE_NAMING = load_shared_fixture("traces")["file_naming"]["cases"]


def test_the_discovery_members_have_cases() -> None:
    for member in ("exporter_template", "traces_dir", "missing_directory"):
        assert OTLP[member]["cases"], member
    assert FILE_NAMING


@pytest.mark.parametrize("case", FILE_NAMING, ids=lambda case: case["file"])
def test_local_trace_files_are_named_as_the_shared_fixture_pins(
    case: dict[str, Any], tmp_path: Path
) -> None:
    _write_span(tmp_path / case["file"], case["file"])
    assert len(read_local_spans(tmp_path)) == (1 if case["read"] else 0)


@pytest.mark.parametrize(
    "case", OTLP["exporter_template"]["cases"], ids=lambda case: case["name"]
)
def test_local_trace_files_follow_an_exporter_template(
    case: dict[str, Any], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(EXPORTER_FILE_VAR, str(tmp_path / case["template"]))
    for name in case["files"]:
        _write_span(tmp_path / name, name)
    assert {span.span_id for span in read_local_spans(tmp_path)} == set(case["read"])


@pytest.mark.parametrize(
    "case", OTLP["traces_dir"]["cases"], ids=lambda case: case["name"]
)
def test_the_traces_dir_follows_the_shared_fixture(
    case: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    for var, value in (
        (EXPORTER_FILE_VAR, case["exporter_file"]),
        (TRACES_DIR_VAR, case["commons_traces_dir"]),
    ):
        if value is not None:
            monkeypatch.setenv(var, value)
    assert local_traces_dir() == Path(case["dir"])


def test_the_traces_dir_defaults_under_the_temporary_directory() -> None:
    assert local_traces_dir() == Path(tempfile.gettempdir()) / "commons-traces"


@pytest.mark.parametrize(
    "case", OTLP["missing_directory"]["cases"], ids=lambda case: case["name"]
)
def test_a_path_that_is_not_a_directory_reads_as_no_spans(
    case: dict[str, Any], tmp_path: Path
) -> None:
    path = tmp_path / case["path"]
    if case["file"]:
        _write_span(path, "s1")
    assert read_local_spans(path) == []
    assert trajectory_read(path) == {}


TRACES = SHARED_DIR / "traces"
WRITERS = ("python", "r")
COMMONS_SPANS = Counter(
    {
        "commons_data_source_create": 2,
        "commons_data_source_load_frames": 2,
        "commons_agent_create": 2,
        "commons_conversation_turn": 3,
        "invoke_agent": 3,
        "chat claude-sonnet-4-5": 4,
        "execute_tool run_sql": 1,
        "commons_provenance": 3,
    }
)


@pytest.mark.parametrize("writer", WRITERS)
def test_each_committed_trace_reads_as_its_spans(writer: str) -> None:
    spans = read_local_spans(TRACES / writer)
    named = [span for span in spans if span.name in COMMONS_SPANS]

    assert Counter(span.name for span in named) == COMMONS_SPANS
    by_id = {span.span_id: span for span in spans}
    roots = {
        "commons_conversation_turn",
        "commons_data_source_create",
        "commons_agent_create",
    }
    parents = {
        "commons_data_source_load_frames": "commons_data_source_create",
        "invoke_agent": "commons_conversation_turn",
        "commons_provenance": "commons_conversation_turn",
        "chat claude-sonnet-4-5": "invoke_agent",
        "execute_tool run_sql": "invoke_agent",
    }
    for span in named:
        if span.name in roots:
            assert span.parent_span_id == ""
        else:
            assert by_id[span.parent_span_id].name == parents[span.name]
            assert by_id[span.parent_span_id].trace_id == span.trace_id
        assert 0 < span.start_time_unix_nano <= span.end_time_unix_nano
    loads = [s for s in spans if s.name == "commons_data_source_load_frames"]
    assert all(s.attributes["commons.data_source.n_tables"] == 2 for s in loads)


def test_a_timestamp_too_large_for_an_integer_reads_as_zero() -> None:
    envelope = {
        "resourceSpans": [
            {
                "scopeSpans": [
                    {
                        "spans": [
                            {"spanId": "s1", "startTimeUnixNano": 1e309},
                            {"spanId": "s2"},
                        ]
                    }
                ]
            }
        ]
    }
    spans = parse_otlp_lines([json.dumps(envelope)])
    assert [s.span_id for s in spans] == ["s1", "s2"]
    assert spans[0].start_time_unix_nano == 0


@pytest.mark.parametrize("value", ["abc", "", "1e", "9x"])
def test_an_integer_that_is_not_a_number_decodes_to_none(value: str) -> None:
    assert otlp_attribute_value({"intValue": value}) is None


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("9007199254740993", 9007199254740993),
        (10**309, 10**309),
        ("1e309", float("inf")),
        (1e309, float("inf")),
    ],
)
def test_an_integer_outside_double_precision_decodes(
    value: object, expected: float
) -> None:
    assert otlp_attribute_value({"intValue": value}) == expected


def test_a_bad_integer_does_not_stop_the_parse() -> None:
    envelope = {
        "resourceSpans": [
            {
                "scopeSpans": [
                    {
                        "spans": [
                            {
                                "spanId": "s1",
                                "attributes": [
                                    {"key": "n", "value": {"intValue": "abc"}}
                                ],
                            },
                            {"spanId": "s2"},
                        ]
                    }
                ]
            }
        ]
    }
    spans = parse_otlp_lines([json.dumps(envelope)])
    assert [s.span_id for s in spans] == ["s1", "s2"]
    assert spans[0].attributes == {"n": None}


def test_an_array_without_a_list_of_values_decodes_to_an_empty_list() -> None:
    assert otlp_attribute_value({"arrayValue": {"values": "x"}}) == []
    assert otlp_attribute_value({"arrayValue": "x"}) == []


def test_files_are_split_on_newlines_only(tmp_path: Path) -> None:
    envelope = {
        "resourceSpans": [
            {"scopeSpans": [{"spans": [{"spanId": "s1", "name": "a\u2028b"}]}]}
        ]
    }
    text = json.dumps(envelope, ensure_ascii=False)
    assert "\u2028" in text
    (tmp_path / "trace-1.jsonl").write_text(
        text + "\r\n" + text + "\n", encoding="utf-8", newline=""
    )
    spans = read_local_spans(tmp_path)
    assert [s.name for s in spans] == ["a\u2028b", "a\u2028b"]


def test_an_empty_traces_dir_variable_reads_as_no_spans(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _write_span(tmp_path / "trace-1.jsonl", "s1")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv(TRACES_DIR_VAR, "")
    assert read_local_spans(local_traces_dir()) == []

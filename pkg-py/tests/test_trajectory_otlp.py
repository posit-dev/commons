"""Tests for reading OTLP trace lines into spans.

The cases live in ``tests/shared/trajectories/otlp.json``, and the R suite runs
the same cases, so a case belongs in the fixture rather than here. This module
adds only what the fixture cannot pin.
"""

import json
from typing import Any

import pytest

from commons._trajectory._otlp import otlp_attribute_value, parse_otlp_lines
from tests._shared import load_shared_fixture

OTLP = load_shared_fixture("trajectories/otlp")


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

"""Parse OTLP JSON trace lines into spans."""

import json
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Span:
    trace_id: str
    span_id: str
    parent_span_id: str  # "" for a root span
    name: str
    start_time_unix_nano: int  # 0 when absent
    end_time_unix_nano: int  # 0 when absent
    attributes: dict[str, Any]  # decoded values; first value wins for a repeated key


def _text(value: Any) -> str:
    return "" if value is None else str(value)


def _nanos(value: Any) -> int:
    if value is None:
        return 0
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _entries(parent: dict[str, Any], key: str) -> list[dict[str, Any]]:
    entries = parent.get(key)
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]


def otlp_attribute_value(value: Any) -> Any:
    """Decode one OTLP attribute value; an encoding not decoded is returned as written."""
    if not isinstance(value, dict):
        return value
    if value.get("stringValue") is not None:
        return value["stringValue"]
    if value.get("intValue") is not None:
        return int(value["intValue"])
    if value.get("doubleValue") is not None:
        return value["doubleValue"]
    if value.get("boolValue") is not None:
        return value["boolValue"]
    if value.get("arrayValue") is not None:
        array = value["arrayValue"]
        values = array.get("values", []) if isinstance(array, dict) else []
        return [otlp_attribute_value(v) for v in values]
    return value


def _otlp_span(span: dict[str, Any]) -> Span:
    attributes: dict[str, Any] = {}
    for attribute in _entries(span, "attributes"):
        attributes.setdefault(
            _text(attribute.get("key")), otlp_attribute_value(attribute.get("value"))
        )
    return Span(
        trace_id=_text(span.get("traceId")),
        span_id=_text(span.get("spanId")),
        parent_span_id=_text(span.get("parentSpanId")),
        name=_text(span.get("name")),
        start_time_unix_nano=_nanos(span.get("startTimeUnixNano")),
        end_time_unix_nano=_nanos(span.get("endTimeUnixNano")),
        attributes=attributes,
    )


def parse_otlp_lines(lines: Iterable[str]) -> list[Span]:
    """Read the spans of OTLP envelopes, one per line; a line that is not one is skipped."""
    spans: list[Span] = []
    for line in lines:
        try:
            envelope = json.loads(line)
        except ValueError:
            continue
        if not isinstance(envelope, dict):
            continue
        for resource in _entries(envelope, "resourceSpans"):
            for scope in _entries(resource, "scopeSpans"):
                spans.extend(_otlp_span(span) for span in _entries(scope, "spans"))
    return spans

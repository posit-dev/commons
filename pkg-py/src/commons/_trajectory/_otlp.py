"""Parse OTLP JSON trace lines into spans."""

import json
import os
import re
import tempfile
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

EXPORTER_FILE_VAR = "OTEL_EXPORTER_OTLP_TRACES_FILE"
TRACES_DIR_VAR = "COMMONS_TRACES_DIR"


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
    except (TypeError, ValueError, OverflowError):
        return 0


def _number(value: Any) -> int | float | None:
    """Decode an ``intValue`` as ``tests/shared/trajectories/otlp.json`` pins it.

    OTLP JSON writes 64-bit integers as strings. A whole number decodes to an
    int, so one past 2**53 keeps every digit. A fraction decodes to a float,
    and a value that is not a number decodes to None.
    """
    if not isinstance(value, float):
        try:
            return int(value)
        except (TypeError, ValueError):
            pass
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    return int(number) if number.is_integer() else number


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
        return _number(value["intValue"])
    if value.get("doubleValue") is not None:
        return value["doubleValue"]
    if value.get("boolValue") is not None:
        return value["boolValue"]
    if value.get("arrayValue") is not None:
        array = value["arrayValue"]
        values = array.get("values") if isinstance(array, dict) else None
        if not isinstance(values, list):
            return []
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
    return [span for line in lines for span in parse_otlp_line(line)[0]]


def parse_otlp_line(line: str) -> tuple[list[Span], int | None]:
    """The spans of one OTLP envelope, and the time Connect sorts the line by.

    Connect sorts trace lines by the start time of the line's first span. The
    time is None when that span is missing or records no start time.
    """
    try:
        envelope = json.loads(line)
    except ValueError:
        return [], None
    if not isinstance(envelope, dict):
        return [], None
    spans = [
        _otlp_span(span)
        for resource in _entries(envelope, "resourceSpans")
        for scope in _entries(resource, "scopeSpans")
        for span in _entries(scope, "spans")
    ]
    return spans, _sort_time(envelope)


def _sort_time(envelope: dict[str, Any]) -> int | None:
    value: Any = envelope
    for key in ("resourceSpans", "scopeSpans", "spans"):
        entries = value.get(key) if isinstance(value, dict) else None
        if not isinstance(entries, list) or not entries:
            return None
        value = entries[0]
    start = value.get("startTimeUnixNano") if isinstance(value, dict) else None
    if not isinstance(start, str) or not re.fullmatch(r"[0-9]+", start):
        return None
    return int(start)


def local_traces_pattern() -> re.Pattern[str]:
    """Match the numbered trace files, and files named from an exporter template.

    ``trace-latest.jsonl`` is excluded because it is a hard link to the newest
    numbered file, so reading it would duplicate that file's spans.
    """
    patterns = [r"trace(?:-[0-9]+)?\.jsonl"]
    template = os.path.basename(os.environ.get(EXPORTER_FILE_VAR, ""))
    if template:
        patterns.append(re.escape(template).replace("%N", "[0-9]+"))
    return re.compile("^(?:" + "|".join(patterns) + ")$")


def local_traces_dir() -> Path:
    """The directory that holds the trace files when no source is given."""
    exporter_file = os.environ.get(EXPORTER_FILE_VAR, "")
    if exporter_file:
        return Path(exporter_file).parent
    value = os.environ.get(
        TRACES_DIR_VAR, os.path.join(tempfile.gettempdir(), "commons-traces")
    )
    # Path("") is the working directory, but an empty value names no directory.
    return Path(value) if value else Path(os.devnull)


def read_local_spans(path: Path) -> list[Span]:
    """Read the spans of the trace files in a directory, in file-name order."""
    if not path.is_dir():
        return []
    pattern = local_traces_pattern()
    files = sorted(p for p in path.iterdir() if p.is_file() and pattern.match(p.name))
    lines: list[str] = []
    for file in files:
        # Split on newlines only: splitlines() also splits on U+2028 and the like.
        text = file.read_text(encoding="utf-8", errors="replace")
        lines.extend(text.split("\n"))
    return parse_otlp_lines(lines)

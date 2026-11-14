"""One recording span exporter for the whole test session.

OpenTelemetry accepts one global tracer provider per process, so the first
caller installs it and every later caller shares its exporter.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from opentelemetry.sdk.trace import ReadableSpan
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
        InMemorySpanExporter,
    )

_EXPORTER: InMemorySpanExporter | None = None


def exporter() -> InMemorySpanExporter:
    """Install the recording provider on first call, and return its exporter.

    The SDK ships in the `tracing` extra, so a plain environment skips the
    test that asks for spans.
    """
    global _EXPORTER
    if _EXPORTER is None:
        pytest.importorskip("opentelemetry.sdk")
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import SimpleSpanProcessor
        from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
            InMemorySpanExporter,
        )

        recording = InMemorySpanExporter()
        provider = TracerProvider()
        provider.add_span_processor(SimpleSpanProcessor(recording))
        trace.set_tracer_provider(provider)
        _EXPORTER = recording
    return _EXPORTER


def finished(name: str | None = None) -> list[ReadableSpan]:
    """The spans finished so far, optionally only those called `name`."""
    spans = exporter().get_finished_spans()
    return [span for span in spans if name is None or span.name == name]

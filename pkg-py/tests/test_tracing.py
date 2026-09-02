"""Setup spans: what commons records, and what happens without OpenTelemetry.

The span and attribute names used here are examples that exercise the helper.
Nothing emits them yet: the names commons really records arrive with the
modules that record them (kata w0t2), and the span contract R reads a
trajectory back through is pinned by a shared fixture (kata 4frb).
"""

from __future__ import annotations

import subprocess
import sys
import textwrap
from collections.abc import Iterator

import pytest

# The SDK ships in the `tracing` extra. CI installs every extra, so these run
# there; a plain dev environment skips them rather than failing to import.
pytest.importorskip("opentelemetry.sdk")

from opentelemetry import trace
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)

from commons._tracing import TRACER_NAME, commons_span

# The global tracer provider can only be set once per process, so one provider
# serves the whole module and each test clears the exporter instead.
_EXPORTER = InMemorySpanExporter()


@pytest.fixture(scope="module", autouse=True)
def _tracing_provider() -> Iterator[None]:
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(_EXPORTER))
    trace.set_tracer_provider(provider)
    yield
    provider.shutdown()


@pytest.fixture(autouse=True)
def _clear_exporter() -> Iterator[None]:
    _EXPORTER.clear()
    yield
    _EXPORTER.clear()


def exported() -> tuple[ReadableSpan, ...]:
    return _EXPORTER.get_finished_spans()


def test_span_is_recorded_with_its_name() -> None:
    with commons_span("commons_data_source_create"):
        pass

    (span,) = exported()
    assert span.name == "commons_data_source_create"


def test_span_carries_the_commons_tracer_name() -> None:
    # The scope name identifies commons as the emitter in a shared trace
    # store, alongside chatlas' own spans.
    with commons_span("commons_agent_create"):
        pass

    (span,) = exported()
    assert span.instrumentation_scope is not None
    assert span.instrumentation_scope.name == TRACER_NAME
    assert TRACER_NAME == "co.posit.python-package.commons"


def test_attributes_given_at_the_start_are_recorded() -> None:
    # Attributes are best set at creation: samplers only see those, and
    # Connect snapshots them when the span opens.
    with commons_span(
        "commons_data_source_create", {"commons.data_source.kind": "duckdb"}
    ):
        pass

    (span,) = exported()
    assert span.attributes is not None
    assert span.attributes["commons.data_source.kind"] == "duckdb"


def test_attributes_set_during_the_span_are_recorded() -> None:
    # Some values, a row count for instance, are only known once the work the
    # span covers has started.
    with commons_span("commons_data_source_list_tables") as span:
        span.set_attribute("commons.data_source.n_tables", 3)

    (recorded,) = exported()
    assert recorded.attributes is not None
    assert recorded.attributes["commons.data_source.n_tables"] == 3


def test_a_nested_span_parents_to_the_enclosing_one() -> None:
    # The span is made current, not merely started: turn grouping depends on
    # spans opened inside it becoming its children.
    with (
        commons_span("commons_context_prewarm"),
        commons_span("commons_context_store_build"),
    ):
        pass

    child, parent = exported()
    assert child.name == "commons_context_store_build"
    assert parent.name == "commons_context_prewarm"
    assert child.parent is not None
    assert parent.context is not None
    assert child.parent.span_id == parent.context.span_id


def test_the_span_ends_and_records_the_error_when_the_body_raises() -> None:
    with (
        pytest.raises(ValueError, match="no such table"),
        commons_span("commons_data_source_list_tables"),
    ):
        raise ValueError("no such table")

    (span,) = exported()
    assert span.end_time is not None
    assert span.status.is_ok is False
    assert [event.name for event in span.events] == ["exception"]


def run_in_fresh_interpreter(body: str) -> str:
    """Run `body` in a new process, where commons has configured nothing."""
    result = subprocess.run(
        [sys.executable, "-c", textwrap.dedent(body)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    return result.stdout


def test_spans_are_inert_when_no_tracer_provider_is_configured() -> None:
    # Setup spans are not gated behind `log=True`, so they open on every
    # agent. With no provider they must cost nothing.
    output = run_in_fresh_interpreter(
        """
        from commons._tracing import commons_span

        with commons_span("commons_agent_create", {"a": 1}) as span:
            span.set_attribute("b", 2)
            print(span.is_recording())
        """
    )
    assert output.strip() == "False"

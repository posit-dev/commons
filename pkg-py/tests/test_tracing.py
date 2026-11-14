"""Setup spans and trajectory logging: what commons records, and when.

The span and attribute names used here are examples that exercise the helper,
not the names commons records.
"""

from __future__ import annotations

import os
import warnings
from collections.abc import Callable
from typing import TYPE_CHECKING, Any

import pytest
from opentelemetry.trace import StatusCode

# The SDK ships in the `tracing` extra. CI installs every extra, so these run
# there; a plain dev environment skips them rather than failing to import.
pytest.importorskip("opentelemetry.sdk")

from commons._tracing import (
    CAPTURE_VAR,
    TRACER_NAME,
    commons_span,
    content_capture_enabled,
    enable_trajectory_tracing,
    tracing_configured,
)

from . import _spans
from ._fresh_interpreter import run_in_fresh_interpreter
from ._shared import load_shared_fixture

if TYPE_CHECKING:
    from opentelemetry.sdk.trace import ReadableSpan

CONTENT_CAPTURE = load_shared_fixture("traces")["content_capture"]


@pytest.fixture(autouse=True)
def _provider() -> None:
    # The logging tests need a configured provider, whether or not they read spans.
    _spans.exporter()


def unset_capture(monkeypatch: pytest.MonkeyPatch) -> None:
    # delenv records nothing for an absent variable, so a value the code sets
    # would outlive the test. setenv first records it for removal.
    monkeypatch.setenv(CAPTURE_VAR, "")
    monkeypatch.delenv(CAPTURE_VAR)


def test_span_is_recorded_with_its_name(
    spans: Callable[..., list[ReadableSpan]],
) -> None:
    with commons_span("commons_data_source_create"):
        pass

    (span,) = spans()
    assert span.name == "commons_data_source_create"


def test_span_carries_the_commons_tracer_name(
    spans: Callable[..., list[ReadableSpan]],
) -> None:
    # The scope name identifies commons as the emitter in a shared trace
    # store, alongside chatlas' own spans.
    with commons_span("commons_agent_create"):
        pass

    (span,) = spans()
    assert span.instrumentation_scope is not None
    assert span.instrumentation_scope.name == TRACER_NAME
    assert TRACER_NAME == "co.posit.python-package.commons"


def test_attributes_given_at_the_start_are_recorded(
    spans: Callable[..., list[ReadableSpan]],
) -> None:
    # Attributes are best set at creation: samplers only see those, and
    # Connect snapshots them when the span opens.
    with commons_span(
        "commons_data_source_create", {"commons.data_source.kind": "duckdb"}
    ):
        pass

    (span,) = spans()
    assert span.attributes is not None
    assert span.attributes["commons.data_source.kind"] == "duckdb"


def test_attributes_set_during_the_span_are_recorded(
    spans: Callable[..., list[ReadableSpan]],
) -> None:
    # Some values, a row count for instance, are only known once the work the
    # span covers has started.
    with commons_span("commons_data_source_list_tables") as span:
        span.set_attribute("commons.data_source.n_tables", 3)

    (recorded,) = spans()
    assert recorded.attributes is not None
    assert recorded.attributes["commons.data_source.n_tables"] == 3


def test_a_nested_span_parents_to_the_enclosing_one(
    spans: Callable[..., list[ReadableSpan]],
) -> None:
    # The span is made current, not merely started: turn grouping depends on
    # spans opened inside it becoming its children.
    with (
        commons_span("commons_context_prewarm"),
        commons_span("commons_context_store_build"),
    ):
        pass

    child, parent = spans()
    assert child.name == "commons_context_store_build"
    assert parent.name == "commons_context_prewarm"
    assert child.parent is not None
    assert parent.context is not None
    assert child.parent.span_id == parent.context.span_id


def test_the_span_ends_without_recording_the_error_when_the_body_raises(
    spans: Callable[..., list[ReadableSpan]],
) -> None:
    with (
        pytest.raises(ValueError, match="no such table"),
        commons_span("commons_data_source_list_tables"),
    ):
        raise ValueError("no such table")

    (span,) = spans()
    assert span.end_time is not None
    # The message can carry query text, so it never reaches the trace.
    assert span.status.status_code is StatusCode.UNSET
    assert span.status.description is None
    assert span.events == ()


def test_the_shared_capture_fixture_has_cases() -> None:
    assert CONTENT_CAPTURE["variable"] == CAPTURE_VAR
    assert CONTENT_CAPTURE["cases"]


@pytest.mark.parametrize(
    "case", CONTENT_CAPTURE["cases"], ids=lambda case: case["name"]
)
def test_content_capture_matches_the_shared_cases(
    monkeypatch: pytest.MonkeyPatch, case: dict[str, Any]
) -> None:
    if case["value"] is None:
        unset_capture(monkeypatch)
    else:
        monkeypatch.setenv(CAPTURE_VAR, case["value"])

    with warnings.catch_warnings():
        warnings.simplefilter("error")
        enabled = content_capture_enabled()

    assert enabled is case["enabled"]
    assert os.environ[CAPTURE_VAR] == case["after"]


def test_tracing_is_reported_as_configured_once_a_provider_is_installed() -> None:
    # The autouse fixture installed one, so this is the configured case.
    assert tracing_configured() is True


def test_logging_off_leaves_capture_alone(monkeypatch: pytest.MonkeyPatch) -> None:
    unset_capture(monkeypatch)

    assert enable_trajectory_tracing(log=False) is False
    assert CAPTURE_VAR not in os.environ


def test_logging_on_with_tracing_active_turns_capture_on(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    unset_capture(monkeypatch)

    assert enable_trajectory_tracing(log=True) is True
    assert os.environ[CAPTURE_VAR] == "true"


def test_logging_on_with_capture_turned_off_is_not_stamped(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Spans without the messages read back as an empty trajectory.
    monkeypatch.setenv(CAPTURE_VAR, "false")

    assert enable_trajectory_tracing(log=True) is False
    assert os.environ[CAPTURE_VAR] == "false"


@pytest.mark.parametrize(
    "env",
    [{}, {"OTEL_TRACES_EXPORTER": "otlp"}],
    ids=["nothing configured", "an exporter named but no provider installed"],
)
def test_logging_on_without_a_provider_configures_nothing(
    env: dict[str, str],
) -> None:
    # commons installs no provider of its own, and with nothing to send spans
    # to it leaves the capture variable as it found it.
    output = run_in_fresh_interpreter(
        """
        import os

        from opentelemetry import trace

        from commons._tracing import CAPTURE_VAR, enable_trajectory_tracing

        os.environ.pop(CAPTURE_VAR, None)
        print(enable_trajectory_tracing(log=True))
        print(CAPTURE_VAR in os.environ)
        print(isinstance(trace.get_tracer_provider(), trace.ProxyTracerProvider))
        """,
        **env,
    )

    assert output.split() == ["False", "False", "True"]


def test_logging_on_with_a_no_op_provider_is_not_stamped() -> None:
    # Installing a no-op provider is a decision to turn tracing off.
    output = run_in_fresh_interpreter(
        """
        import os

        from opentelemetry import trace

        from commons._tracing import CAPTURE_VAR, enable_trajectory_tracing

        os.environ.pop(CAPTURE_VAR, None)
        trace.set_tracer_provider(trace.NoOpTracerProvider())
        print(enable_trajectory_tracing(log=True))
        print(CAPTURE_VAR in os.environ)
        """
    )

    assert output.split() == ["False", "False"]

"""Setup spans and trajectory logging: what commons records, and when.

The span and attribute names used here are examples that exercise the helper,
not the names commons records.
"""

from __future__ import annotations

import os
import warnings
from collections.abc import Callable
from typing import TYPE_CHECKING, Any

import httpx
import pytest

# The SDK ships in the `tracing` extra. CI installs every extra, so these run
# there; a plain dev environment skips them rather than failing to import.
pytest.importorskip("opentelemetry.sdk")

from commons import _tracing
from commons._connect import ConnectClient
from commons._tracing import (
    CAPTURE_VAR,
    TRACER_NAME,
    commons_span,
    content_capture_enabled,
    enable_content_observability,
    enable_trajectory_tracing,
    tracing_configured,
    warn_if_connect_tracing_unsupported,
)

from . import _spans
from ._fresh_interpreter import run_in_fresh_interpreter
from ._shared import load_shared_fixture

if TYPE_CHECKING:
    from opentelemetry.sdk.trace import ReadableSpan

CONTENT_CAPTURE = load_shared_fixture("traces")["content_capture"]
CONNECT = load_shared_fixture("connect")
OBSERVABILITY = CONNECT["observability"]


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


def test_the_span_ends_and_records_the_error_when_the_body_raises(
    spans: Callable[..., list[ReadableSpan]],
) -> None:
    with (
        pytest.raises(ValueError, match="no such table"),
        commons_span("commons_data_source_list_tables"),
    ):
        raise ValueError("no such table")

    (span,) = spans()
    assert span.end_time is not None
    assert span.status.is_ok is False
    assert [event.name for event in span.events] == ["exception"]


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


# Phrases that tell the warnings apart. Each one occurs in exactly one warning.
WARNING_PHRASES = {
    "requires Connect >=": "version",
    "disabled by this Posit Connect": "disabled",
    "Enabled Content Observability": "toggled",
    "Content Observability is enabled": "already_on",
    "OpenTelemetry tracing is not active": "failed",
}


def warning_kind(warning: warnings.WarningMessage) -> str:
    text = str(warning.message)
    (kind,) = {kind for phrase, kind in WARNING_PHRASES.items() if phrase in text}
    return kind


def connect_client(
    handler: Callable[[httpx.Request], httpx.Response],
) -> ConnectClient:
    http = httpx.Client(transport=httpx.MockTransport(handler))
    return ConnectClient("https://connect.example.com", "the-api-key", http=http)


@pytest.fixture
def on_connect(monkeypatch: pytest.MonkeyPatch) -> None:
    environment = CONNECT["environment"]
    monkeypatch.delenv(environment["product"], raising=False)
    monkeypatch.setenv(environment["content_guid"], "content-guid")


@pytest.fixture
def fresh_attempt(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(_tracing, "_OBSERVABILITY_ATTEMPTED", False)


def settings_client(settings: object) -> ConnectClient:
    def answer(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/__api__/server_settings"
        if settings is None:
            return httpx.Response(500)
        return httpx.Response(200, json=settings)

    return connect_client(answer)


def content_client(
    case: dict[str, Any],
) -> tuple[ConnectClient, list[httpx.Request]]:
    seen: list[httpx.Request] = []

    def answer(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if request.method == "PATCH":
            return httpx.Response(500 if case.get("patch_fails") else 200, json={})
        if case["content"] is None:
            return httpx.Response(500)
        return httpx.Response(200, json=case["content"])

    return connect_client(answer), seen


@pytest.mark.parametrize(
    "case",
    OBSERVABILITY["server_settings"]["cases"],
    ids=lambda case: case["name"],
)
def test_the_server_warning_follows_the_shared_cases(
    case: dict[str, Any], on_connect: None
) -> None:
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        warn_if_connect_tracing_unsupported(client=settings_client(case["settings"]))

    kinds = [warning_kind(warning) for warning in caught]
    assert kinds == ([] if case["warns"] is None else [case["warns"]])


def test_the_version_warning_names_the_server_version(on_connect: None) -> None:
    with pytest.warns(UserWarning, match=r"running Connect 2026\.08\.1") as caught:
        warn_if_connect_tracing_unsupported(
            client=settings_client({"version": "2026.08.1"})
        )

    assert "2026.09.0" in str(caught[0].message)


@pytest.mark.parametrize(
    "case", OBSERVABILITY["enable"]["cases"], ids=lambda case: case["name"]
)
def test_enablement_follows_the_shared_cases(
    case: dict[str, Any], on_connect: None, fresh_attempt: None
) -> None:
    client, seen = content_client(case)

    with pytest.warns(UserWarning) as caught:
        enable_content_observability(client=client)

    assert ("PATCH" in [request.method for request in seen]) is case["patched"]
    assert [warning_kind(warning) for warning in caught] == [case["outcome"]]


def test_enablement_is_attempted_once_per_process(
    on_connect: None, fresh_attempt: None
) -> None:
    client, seen = content_client({"content": {"otel_enabled": False}})
    with pytest.warns(UserWarning):
        enable_content_observability(client=client)
    requests_made = len(seen)

    with warnings.catch_warnings():
        warnings.simplefilter("error")
        enable_content_observability(client=client)

    assert len(seen) == requests_made


def test_neither_check_asks_connect_anything_off_connect(
    monkeypatch: pytest.MonkeyPatch, fresh_attempt: None
) -> None:
    environment = CONNECT["environment"]
    monkeypatch.delenv(environment["product"], raising=False)
    monkeypatch.delenv(environment["content_guid"], raising=False)
    client, seen = content_client({"content": {"otel_enabled": False}})

    with warnings.catch_warnings():
        warnings.simplefilter("error")
        warn_if_connect_tracing_unsupported(client=client)
        enable_content_observability(client=client)

    assert seen == []


def test_enablement_without_credentials_warns_instead_of_raising(
    monkeypatch: pytest.MonkeyPatch, on_connect: None, fresh_attempt: None
) -> None:
    environment = CONNECT["environment"]
    monkeypatch.delenv(environment["server"], raising=False)
    monkeypatch.delenv(environment["api_key"], raising=False)

    with pytest.warns(UserWarning) as caught:
        enable_content_observability()

    assert [warning_kind(warning) for warning in caught] == ["failed"]

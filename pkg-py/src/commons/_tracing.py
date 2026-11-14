"""OpenTelemetry spans for commons.

Setup spans record product setup, such as building a data source or
constructing an agent, and not conversation content. An agent's ``log``
argument does not gate them. Until an SDK provider is configured, the
OpenTelemetry API is inert: a span does not record and costs almost
nothing. This makes the API safe as a hard dependency, so commons
requires it and leaves the SDK and the exporters to the ``tracing``
extra. ``pkg-r/R/tracing.R`` holds the R counterparts.
"""

from __future__ import annotations

import os
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from typing import Any

from opentelemetry import trace
from opentelemetry.trace import Span

__all__ = [
    "CAPTURE_VAR",
    "TRACER_NAME",
    "Span",
    "commons_span",
    "content_capture_enabled",
    "enable_trajectory_tracing",
    "tracing_configured",
]

# Whether chat spans include the messages. Without it a trajectory reads empty.
CAPTURE_VAR = "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"

# Identifies commons as the emitter, alongside chatlas' own spans. R uses
# `co.posit.r-package.commons`.
TRACER_NAME = "co.posit.python-package.commons"

# Resolved once. With no provider configured this is a proxy that re-checks the
# global provider each time a span opens, so a provider installed later still
# takes effect.
_TRACER = trace.get_tracer(TRACER_NAME)


@contextmanager
def commons_span(
    name: str, attributes: Mapping[str, Any] | None = None
) -> Iterator[Span]:
    """Open a span, current for the duration of the block, and end it on exit.

    Pass the values known up front in ``attributes``: samplers see only
    those, and Connect snapshots a span's attributes when it opens. Set
    values that the work produces, such as a row count, on the yielded
    span.
    """
    with _TRACER.start_as_current_span(name, attributes=attributes) as span:
        yield span


def enable_trajectory_tracing(*, log: bool) -> bool:
    """Say whether to stamp conversation spans for trajectory logging.

    ``True`` only when ``log`` is set, a tracer provider is configured, and
    message content capture is on. commons configures no exporter: where
    the spans go is the caller's OpenTelemetry setup. Capture is checked
    last, so a process with no tracing keeps its environment unchanged.
    """
    if not log:
        return False
    if not tracing_configured():
        return False
    return content_capture_enabled()


def tracing_configured() -> bool:
    """Is there a tracer provider that does something with spans?

    Says nothing about whether that provider exports them anywhere. A provider
    with no span processor, or one sampling nothing, records and discards, and
    only its owner can know that.
    """
    provider = trace.get_tracer_provider()
    return not isinstance(
        provider, trace.ProxyTracerProvider | trace.NoOpTracerProvider
    )


def content_capture_enabled() -> bool:
    """Is GenAI message content capture on? Turn it on if nothing set it.

    chatlas reads the variable on every call, so setting it here takes effect
    from the next chat. An explicit value other than ``"true"`` or ``"1"`` is
    a deliberate opt-out and is left alone.
    """
    current = os.environ.get(CAPTURE_VAR, "")
    if current.lower() in ("true", "1"):
        return True
    if current:
        return False
    os.environ[CAPTURE_VAR] = "true"
    return True

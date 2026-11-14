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
import warnings
from collections.abc import Iterator, Mapping
from contextlib import contextmanager, nullcontext
from typing import Any

from opentelemetry import trace
from opentelemetry.trace import Span

from ._connect import (
    MINIMUM_TRACING_VERSION,
    ConnectClient,
    ConnectError,
    connect_content_guid,
    content,
    enable_otel,
    is_connect_runtime,
    parse_connect_version,
    server_settings,
    version_is_older,
)

__all__ = [
    "CAPTURE_VAR",
    "TRACER_NAME",
    "Span",
    "commons_span",
    "content_capture_enabled",
    "enable_content_observability",
    "enable_trajectory_tracing",
    "tracing_configured",
    "warn_if_connect_tracing_unsupported",
]

# Whether chat spans include the messages. Without it a trajectory reads empty.
CAPTURE_VAR = "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"

# Identifies commons as the emitter, alongside chatlas' own spans. R uses
# `co.posit.r-package.commons`.
TRACER_NAME = "co.posit.python-package.commons"

# Set before the first request, so the API calls are made once per process.
_OBSERVABILITY_ATTEMPTED = False

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


def warn_if_connect_tracing_unsupported(*, client: ConnectClient | None = None) -> None:
    """Warn when this Connect server cannot record trajectories.

    The server must be at least ``MINIMUM_TRACING_VERSION`` and must allow
    content instrumentation. The version is checked first. The settings
    endpoint is internal, so a failed request or a missing field means
    unknown and warns about nothing. Does nothing off Connect.
    """
    if not is_connect_runtime():
        return
    try:
        with (
            ConnectClient.from_env() if client is None else nullcontext(client)
        ) as connect:
            settings = server_settings(connect)
    except (ConnectError, ValueError):
        return

    version = parse_connect_version(settings.get("version"))
    if version is not None and version_is_older(version, MINIMUM_TRACING_VERSION):
        warnings.warn(
            f"This server is running Connect {settings['version']}, but "
            "trajectory logging requires Connect >= 2026.09.0. "
            "Please ask your server administration to upgrade.",
            stacklevel=2,
        )
    elif settings.get("allow_content_instrumentation") is False:
        warnings.warn(
            "Trajectory logging is disabled by this Posit Connect server's "
            "configuration. Ask your server administrator to set "
            "OpenTelemetry.Enabled = true and "
            "OpenTelemetry.AllowContentInstrumentation = true in the Connect "
            "configuration, then restart Connect.",
            stacklevel=2,
        )


def enable_content_observability(*, client: ConnectClient | None = None) -> None:
    """Turn on this content's Content Observability setting, and say so.

    For a process that started without tracing. Connect injects the exporter
    configuration only into processes started after the setting is on, so this
    process stays untraced and the warning says when logging begins. The
    setting is editable with the ephemeral owner-scoped ``CONNECT_API_KEY``
    that Connect gives running content. Attempted once per process, since an
    agent is typically built per session. Does nothing off Connect. A Connect
    failure warns and never raises.
    """
    global _OBSERVABILITY_ATTEMPTED
    if not is_connect_runtime() or _OBSERVABILITY_ATTEMPTED:
        return
    _OBSERVABILITY_ATTEMPTED = True

    try:
        with (
            ConnectClient.from_env() if client is None else nullcontext(client)
        ) as connect:
            guid = connect_content_guid()
            already_on = content(connect, guid).get("otel_enabled") is True
            if not already_on:
                enable_otel(connect, guid)
    except (ConnectError, ValueError):
        warnings.warn(
            "Trajectory logging is enabled but OpenTelemetry tracing is not "
            "active. In this content's Settings > Monitoring > Traces panel "
            "on Posit Connect, select Enabled, then redeploy or restart the "
            "content.",
            stacklevel=2,
        )
        return

    first = (
        "Content Observability is enabled for this content, but this process "
        "started without OpenTelemetry tracing."
        if already_on
        else "Enabled Content Observability for this content, but this "
        "process started without it."
    )
    warnings.warn(
        f"{first} Trajectory logging will begin once the content restarts.",
        stacklevel=2,
    )

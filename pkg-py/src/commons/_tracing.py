"""OpenTelemetry spans for commons.

Setup spans record product setup, such as building a data source or
constructing an agent, and not conversation content. An agent's ``log``
argument does not gate them. Until an SDK provider is configured, the
OpenTelemetry API is inert: a span does not record and costs almost
nothing. This makes the API safe as a hard dependency, so commons
requires it and leaves the SDK and the exporters to the ``tracing``
extra. Trajectory logging setup checks, when an agent is built with
``log=True``, whether conversation spans can record, and on Connect turns on
Content Observability. ``pkg-r/R/tracing.R`` holds the R counterparts.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import warnings
from collections.abc import Iterator, Mapping, Sequence
from contextlib import AbstractContextManager, contextmanager, nullcontext
from typing import TYPE_CHECKING, Any

from opentelemetry import trace
from opentelemetry.trace import Span

from ._connect import (
    MINIMUM_TRACING_VERSION,
    ConnectClient,
    ConnectError,
    check_usernames,
    connect_content_guid,
    content,
    enable_otel,
    is_connect_runtime,
    parse_connect_version,
    server_settings,
    share_trajectory_access,
    version_is_older,
)

if TYPE_CHECKING:
    from ._citations import CitationDecision

__all__ = [
    "CANDIDATES_ATTRIBUTE",
    "CAPTURE_VAR",
    "PROVENANCE_SPAN",
    "TAG_ATTRIBUTE",
    "TRACER_NAME",
    "TURN_SPAN",
    "USER_ATTRIBUTE",
    "Span",
    "as_current",
    "check_trajectory_arguments",
    "citation_candidates_json",
    "commons_span",
    "content_capture_enabled",
    "enable_content_observability",
    "enable_trajectory_tracing",
    "start_turn_span",
    "tracing_configured",
    "trajectory_user",
    "warn_if_connect_tracing_unsupported",
]

# Whether chat spans include the messages. Without it a trajectory reads empty.
CAPTURE_VAR = "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"

# Identifies commons as the emitter, alongside chatlas' own spans. R uses
# `co.posit.r-package.commons`.
TRACER_NAME = "co.posit.python-package.commons"

# The span around one turn of a logging agent, and the session user it records.
TURN_SPAN = "commons_conversation_turn"
USER_ATTRIBUTE = "commons.connect.user"

# The span that records an answer's provenance tag and citation decisions.
PROVENANCE_SPAN = "commons_provenance"
TAG_ATTRIBUTE = "commons.provenance.tag"
CANDIDATES_ATTRIBUTE = "commons.citation.candidates"

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


def start_turn_span(user: str | None) -> Span:
    """Start a turn span under the current one, without making it current.

    The caller ends it. ``user`` is recorded when given.
    """
    return _TRACER.start_span(
        TURN_SPAN, attributes=None if user is None else {USER_ATTRIBUTE: user}
    )


def citation_candidates_json(decisions: Sequence[CitationDecision]) -> str:
    """The decisions as the JSON array the candidates attribute holds.

    A decision's ``label`` and ``kind`` are left out when absent. ``quote``
    is always present and is ``null`` for a malformed body.
    """
    return json.dumps(
        [
            {
                key: value
                for key, value in (
                    ("quote", decision.quote),
                    ("status", decision.status),
                    ("label", decision.label),
                    ("kind", decision.kind),
                )
                if key in ("quote", "status") or value is not None
            }
            for decision in decisions
        ],
        separators=(",", ":"),
    )


def as_current(span: Span | None) -> AbstractContextManager[Any]:
    """Make ``span`` current for the block, leaving it open and its status alone.

    Does nothing when there is no span.
    """
    if span is None:
        return nullcontext()
    return trace.use_span(
        span, end_on_exit=False, record_exception=False, set_status_on_exception=False
    )


_CURRENT_SESSION = object()


def trajectory_user(session: object | None = _CURRENT_SESSION) -> str | None:
    """The authenticated user of ``session``, by default the current Shiny one.

    Only a non-empty string counts. A module's scope reports the user of the
    session it belongs to. Shiny is consulted only when something has
    imported it already, so an agent without the ``shiny`` extra imports
    nothing.
    """
    if session is _CURRENT_SESSION:
        session = None
        if "shiny" in sys.modules:
            from shiny.session import get_current_session

            session = get_current_session()
    root_scope = getattr(session, "root_scope", None)
    if callable(root_scope):
        session = root_scope()
    user = getattr(session, "user", None)
    return user if isinstance(user, str) and user else None


def check_trajectory_arguments(log: object, share_with: Sequence[str] | None) -> None:
    """Raise a TypeError unless `log` is a bool and `share_with` a username sequence."""
    if not isinstance(log, bool):
        raise TypeError("log must be True or False.")
    if share_with is not None:
        check_usernames(share_with)


def enable_trajectory_tracing(
    *, log: bool, share_with: Sequence[str] | None = None, stacklevel: int = 2
) -> bool:
    """Check the tracing setup, and say whether to stamp conversation spans.

    ``True`` only when ``log`` is set, the SDK is installed, a tracer
    provider is configured, and message content capture is on. A missing SDK
    warns. On Connect, an unsupported server warns, and a missing provider
    turns on Content Observability and warns. A missing provider off Connect,
    or a capture opt-out, returns ``False`` silently. ``share_with`` grants
    those Connect users access once logging is live. commons configures no
    exporter: where the spans go is the caller's OpenTelemetry setup. Capture
    is checked last, so a process with no tracing keeps its environment
    unchanged. Every warning is attributed ``stacklevel`` frames up from this
    function.
    """
    check_trajectory_arguments(log, share_with)
    # The helpers warn one frame deeper than this function does.
    nested = stacklevel + 1

    if not log:
        if share_with is not None:
            warnings.warn(
                "share_with only applies when log=True. Ignoring it.",
                stacklevel=stacklevel,
            )
        return False

    warn_if_connect_tracing_unsupported(stacklevel=nested)

    if importlib.util.find_spec("opentelemetry.sdk") is None:
        warnings.warn(
            "Trajectory logging requires the tracing extra. "
            "Install it with: pip install 'commons[tracing]'",
            stacklevel=stacklevel,
        )
        return False

    if not tracing_configured():
        enable_content_observability(stacklevel=nested)
        return False

    if not content_capture_enabled():
        return False

    if share_with is not None:
        share_trajectory_access(share_with, stacklevel=nested)
    return True


def tracing_configured() -> bool:
    """Is there a tracer provider that does something with spans?

    Says nothing about whether that provider exports them anywhere. A provider
    with no span processor, or one sampling nothing, records and discards, and
    only its owner can know that. ``OTEL_SDK_DISABLED=true`` turns the SDK's
    tracers into no-ops whatever provider is installed, so it counts as not
    configured.
    """
    if os.environ.get("OTEL_SDK_DISABLED", "").strip().lower() == "true":
        return False
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


def warn_if_connect_tracing_unsupported(
    *, client: ConnectClient | None = None, stacklevel: int = 2
) -> None:
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
            f"trajectory logging requires Connect >= {MINIMUM_TRACING_VERSION}. "
            "Please ask your server administrator to upgrade.",
            stacklevel=stacklevel,
        )
    elif settings.get("allow_content_instrumentation") is False:
        warnings.warn(
            "Trajectory logging is disabled by this Posit Connect server's "
            "configuration. Ask your server administrator to set "
            "OpenTelemetry.Enabled = true and "
            "OpenTelemetry.AllowContentInstrumentation = true in the Connect "
            "configuration, then restart Connect.",
            stacklevel=stacklevel,
        )


def enable_content_observability(
    *, client: ConnectClient | None = None, stacklevel: int = 2
) -> None:
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
            stacklevel=stacklevel,
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
        stacklevel=stacklevel,
    )

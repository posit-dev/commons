"""OpenTelemetry spans for commons.

Setup spans cover product setup, building a data source or constructing an
agent, rather than conversation content, so they are not gated behind an
agent's ``log`` argument. That is affordable because the OpenTelemetry API is
inert until an SDK provider is configured: without one, a span is a
non-recording stand-in and costs almost nothing. commons therefore requires
the API outright and leaves the SDK and the exporters to the ``tracing``
extra. ``pkg-r/R/tracing.R`` holds the R counterparts.
"""

from __future__ import annotations

import os
import re
import tempfile
import threading
import warnings
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from opentelemetry import trace
from opentelemetry.trace import Span

__all__ = [
    "CAPTURE_VAR",
    "EXPORTER_VAR",
    "TRACER_NAME",
    "TRACES_DIR_VAR",
    "TRACES_FILE_VAR",
    "Span",
    "commons_span",
    "commons_traces_dir",
    "enable_content_capture",
    "enable_trajectory_tracing",
    "next_trace_file",
    "provider_unset",
    "tracing_configured",
]

# Where local trace files go, and where a reader looks for them.
TRACES_DIR_VAR = "COMMONS_TRACES_DIR"
TRACES_FILE_VAR = "OTEL_EXPORTER_OTLP_TRACES_FILE"
# Whether the caller has configured an exporter of their own.
EXPORTER_VAR = "OTEL_TRACES_EXPORTER"
# Whether chat spans carry the messages. Without it a trajectory reads empty.
CAPTURE_VAR = "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"

_NUMBERED_TRACE_FILE = re.compile(r"trace-(\d+)\.jsonl")

# Guards the read-then-install of the global tracer provider.
_SETUP_LOCK = threading.Lock()
# Guards the private default directory, created once per process. Separate
# from _SETUP_LOCK because installation resolves the directory while holding
# that one.
_DEFAULT_DIR_LOCK = threading.Lock()
_DEFAULT_TRACES_DIR: Path | None = None

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

    Set what is already known through ``attributes``: samplers see only those,
    and Connect snapshots a span's attributes when it opens. Values that the
    covered work produces, a row count for instance, go on the yielded span.
    """
    with _TRACER.start_as_current_span(name, attributes=attributes) as span:
        yield span


def enable_trajectory_tracing(*, log: bool) -> bool:
    """Prepare the process to record trajectories, and say whether to stamp them.

    Returns ``False`` when there is nowhere for conversation spans to go,
    either because the caller did not ask or because no provider could be
    configured. ``True`` means commons will emit spans into a configured
    provider. When that provider is the caller's own, where the spans end up
    is theirs to know: commons does not inspect it.
    """
    if not log:
        return False

    enable_content_capture()
    if provider_unset():
        enable_local_tracing()
    if not tracing_configured():
        warnings.warn(
            "Trajectory logging is enabled but OpenTelemetry tracing is not "
            "active. Configure an exporter before the process starts, or let "
            f"commons configure one by leaving {EXPORTER_VAR} unset and "
            "installing no tracer provider of your own.",
            stacklevel=2,
        )
        return False
    return True


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


def provider_unset() -> bool:
    """Has nobody installed a tracer provider yet?

    Distinct from `tracing_enabled()`: an explicitly installed no-op provider
    means tracing is off, but it is a decision, and `set_tracer_provider()`
    refuses to replace it anyway.
    """
    return isinstance(trace.get_tracer_provider(), trace.ProxyTracerProvider)


def enable_content_capture() -> bool:
    """Ask the GenAI instrumentation to record message content.

    An explicitly configured value is respected either way. A deliberate
    opt-out must not be flipped process-wide, but it is worth saying out loud,
    because the trajectory it produces looks like a failed capture.
    """
    configured = os.environ.get(CAPTURE_VAR, "")
    if configured:
        if configured.lower() not in ("true", "1"):
            warnings.warn(
                f"{CAPTURE_VAR} is set to {configured!r}, so logged "
                "trajectories will not include message content. Unset it or "
                'set it to "true" to capture full trajectories.',
                stacklevel=2,
            )
        return False
    os.environ[CAPTURE_VAR] = "true"
    return True


def enable_local_tracing() -> bool:
    """Write spans to a local file, for a session that configured nothing.

    Only steps in when no exporter is configured at all. An explicit
    ``OTEL_TRACES_EXPORTER``, even ``"none"``, is a decision to respect.
    """
    # Checked again under the lock, which is the authoritative read. This one
    # only avoids asking for the `tracing` extra when there was never anything
    # for commons to configure.
    if os.environ.get(EXPORTER_VAR) or not provider_unset():
        return False

    try:
        from opentelemetry.exporter.otlp.json.file import FileSpanExporter
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    except ImportError:
        warnings.warn(
            "Local trajectory logging needs the OpenTelemetry SDK. Install "
            'commons with the "tracing" extra to enable it.',
            stacklevel=2,
        )
        return False

    with _SETUP_LOCK:
        # Both checks belong inside the lock. Reading them outside leaves a
        # window in which a caller configures an exporter that commons then
        # overrides.
        if os.environ.get(EXPORTER_VAR) or not provider_unset():
            return False

        path = next_trace_file(commons_traces_dir())
        provider = TracerProvider()
        # Written as each span ends rather than batched: a batch is lost if
        # the process dies, and losing the last turn of a conversation is the
        # worst span to lose. Appending a line to a local file is cheap.
        provider.add_span_processor(SimpleSpanProcessor(FileSpanExporter(str(path))))
        trace.set_tracer_provider(provider)

        if trace.get_tracer_provider() is not provider:
            # Someone installed one from outside this lock. Their spans go
            # elsewhere, so leave no claimed file and no variable pointing at
            # a file nothing writes to.
            provider.shutdown()
            path.unlink(missing_ok=True)
            return False

        # The file exporter does not read this, but a reader uses it to find
        # the directory, so it must name the file the spans actually go to.
        os.environ[TRACES_FILE_VAR] = str(path)
        return True


def commons_traces_dir() -> Path:
    """Where commons writes trace files when it configures the exporter.

    The default is a directory readable only by this user, created once per
    process, because a trace file holds whole conversations and the shared
    temporary directory is not somewhere to leave those. Set
    ``COMMONS_TRACES_DIR`` to keep them somewhere durable, and to let another
    process read them back.
    """
    global _DEFAULT_TRACES_DIR

    configured = os.environ.get(TRACES_DIR_VAR, "")
    if configured:
        return Path(configured)
    with _DEFAULT_DIR_LOCK:
        if _DEFAULT_TRACES_DIR is None:
            _DEFAULT_TRACES_DIR = Path(tempfile.mkdtemp(prefix="commons-traces-"))
        return _DEFAULT_TRACES_DIR


def next_trace_file(directory: Path) -> Path:
    """Claim an unused numbered trace file in `directory`.

    The Python file exporter appends to one path and rotates nothing, so
    commons picks the name. Claiming it rather than only choosing it keeps two
    processes starting at once from interleaving their spans into one file.
    """
    directory.mkdir(parents=True, exist_ok=True)
    numbers = [
        int(match.group(1))
        for entry in directory.iterdir()
        if (match := _NUMBERED_TRACE_FILE.fullmatch(entry.name))
    ]
    # Gaps are left alone. Filling one would append to a run a reader has
    # already taken.
    number = max(numbers, default=0) + 1
    while True:
        path = directory / f"trace-{number}.jsonl"
        try:
            os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        except FileExistsError:
            number += 1
        else:
            return path

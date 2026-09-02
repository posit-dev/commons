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

from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from typing import Any

from opentelemetry import trace
from opentelemetry.trace import Span

__all__ = ["TRACER_NAME", "Span", "commons_span"]

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

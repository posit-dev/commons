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

    Pass the values known up front in ``attributes``: samplers see only
    those, and Connect snapshots a span's attributes when it opens. Set
    values that the work produces, such as a row count, on the yielded
    span.
    """
    with _TRACER.start_as_current_span(name, attributes=attributes) as span:
        yield span

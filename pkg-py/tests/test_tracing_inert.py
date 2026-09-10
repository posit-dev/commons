"""Setup spans without an SDK: the common case for a plain `commons` install.

This module deliberately sits outside `test_tracing.py`'s
`pytest.importorskip("opentelemetry.sdk")` gate: the guarantee it pins is for
the environments that never install the SDK, so it has to run there too.
"""

from __future__ import annotations

import subprocess
import sys
import textwrap


def run_in_fresh_interpreter(body: str) -> str:
    """Run `body` in a new process, where commons has configured nothing."""
    result = subprocess.run(
        [sys.executable, "-c", textwrap.dedent(body)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    # Native code writes to stderr outside Python's warnings system:
    # onnxruntime (a magika dependency) logs a device-probe warning on the
    # Linux CI runners. Assert only that commons and OpenTelemetry stay
    # quiet; total silence is not commons' to guarantee.
    assert "opentelemetry" not in result.stderr
    assert "commons" not in result.stderr
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

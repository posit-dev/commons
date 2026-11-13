"""Run code in a new interpreter and require commons and OpenTelemetry to stay quiet."""

from __future__ import annotations

import os
import subprocess
import sys
import textwrap

# Fails the child on a warning or log record from commons or OpenTelemetry.
# `__main__` is in the filter because a warning raised with `stacklevel=2` is
# attributed to the body that called the function. Other stderr output is
# allowed: onnxruntime (a magika dependency) logs a device-probe warning on
# the Linux CI runners, and total silence is not commons' to guarantee.
_QUIET_PREAMBLE = """
import logging
import warnings

warnings.filterwarnings(
    "error", module=r"(__main__|commons|opentelemetry)(\\.|$)"
)


class _FailOnRecord(logging.Handler):
    def emit(self, record):
        raise SystemExit(f"{record.name} logged: {record.getMessage()}")


for _name in ("commons", "opentelemetry"):
    logging.getLogger(_name).addHandler(_FailOnRecord(logging.WARNING))
"""


def run_in_fresh_interpreter(body: str, **env: str) -> str:
    """Run `body` in a new process, where no tracer provider is installed."""
    # Drop the caller's OpenTelemetry settings: OTEL_PYTHON_TRACER_PROVIDER,
    # for one, would install a provider on first use.
    inherited = {k: v for k, v in os.environ.items() if not k.startswith("OTEL_")}
    result = subprocess.run(
        [sys.executable, "-c", _QUIET_PREAMBLE + textwrap.dedent(body)],
        capture_output=True,
        text=True,
        check=False,
        env={**inherited, **env},
        timeout=60,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout

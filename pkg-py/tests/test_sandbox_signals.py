"""What a sandboxed worker can signal, driven by a shared fixture.

Whether model code can reach the host, or leave the process group the driver
kills, is a cross-language contract, so the cases live in
``tests/shared/sandbox-signals.json`` and the R suite runs the same ones. Do
not restate a case here; add it to the fixture.
"""

from __future__ import annotations

import asyncio
import os
import platform
import signal
from typing import Any

import pytest

from commons._execution._driver import Worker
from commons._execution._runtime import _landlock
from commons._execution._sandbox import protection_mode
from commons._run_python import run_python_result

from ._shared import load_shared_fixture

SPEC: dict[str, Any] = load_shared_fixture("sandbox-signals")["cases"]

try:
    _PROTECTION = protection_mode()
except RuntimeError:
    _PROTECTION = None

# Where the sandbox confines signals to the worker and its descendants.
SIGNAL_SCOPING = platform.system() == "Darwin" or (
    platform.system() == "Linux" and _landlock.abi_version() >= _landlock.SCOPE_MIN_ABI
)


def test_the_fixture_has_cases() -> None:
    assert SPEC["cases"]


@pytest.mark.skipif(
    _PROTECTION != "sandbox", reason="this host cannot sandbox the worker"
)
@pytest.mark.parametrize("case", SPEC["cases"], ids=lambda case: case["name"])
async def test_worker_signals_follow_the_shared_fixture(case: dict[str, Any]) -> None:
    if "platforms" in case and platform.system().lower() not in case["platforms"]:
        pytest.skip(f"the case covers {', '.join(case['platforms'])} only")
    if case.get("requires") == "signal_scoping" and not SIGNAL_SCOPING:
        pytest.skip("this host's sandbox does not scope signals")

    victim = await asyncio.create_subprocess_exec(
        "sh", "-c", SPEC["victim"], stdout=asyncio.subprocess.PIPE
    )
    code = (
        case["code"]["python"]
        .replace("{host_pid}", str(os.getpid()))
        .replace("{host_group}", str(os.getpgrp()))
        .replace("{victim_pid}", str(victim.pid))
        .replace("{sigurg}", str(int(signal.SIGURG)))
    )
    try:
        async with Worker() as worker:
            output = run_python_result(code, await worker.run(code)).value
        # Long enough for the victim's trap to run between its sleeps.
        await asyncio.sleep(0.3)
    finally:
        victim.terminate()
        heard, _ = await victim.communicate()

    assert output.strip() == case["output"]
    assert heard == b""

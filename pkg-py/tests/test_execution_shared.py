"""The execution tool's REPL behaviour and worker failures, driven by shared fixtures.

What the model reads back from ``run_python``, and the worker's time limits and
failure messages, are cross-language contracts, so the cases live in
``tests/shared/execution-repl.json`` and ``tests/shared/worker-lifecycle.json``
and the R suite runs the same ones. Do not restate a case here; add it to the
fixture.

Every case runs in a real worker, because the text under test is what the
worker and ``run_python_result`` produce together.
"""

from __future__ import annotations

import os
from typing import Any

import pytest

from commons._execution import _driver
from commons._execution._driver import Worker
from commons._execution._sandbox import protection_mode
from commons._run_python import NO_OUTPUT, run_python_result

from ._shared import load_shared_fixture

REPL: dict[str, Any] = load_shared_fixture("execution-repl")["cases"]
LIFECYCLE: dict[str, Any] = load_shared_fixture("worker-lifecycle")

try:
    _PROTECTION = protection_mode()
except RuntimeError:
    _PROTECTION = None

needs_worker = pytest.mark.skipif(
    _PROTECTION is None or os.name != "posix",
    reason="this host cannot sandbox the worker",
)


def for_python(value: Any) -> Any:
    """A fixture value that is either shared or keyed by language."""
    return value["python"] if isinstance(value, dict) else value


async def tool_output(worker: Worker, code: str) -> Any:
    return run_python_result(code, await worker.run(code)).value


def test_the_fixtures_have_cases() -> None:
    assert REPL["cases"]
    assert LIFECYCLE["failures"]["cases"]


def test_a_call_with_no_output_says_so_in_the_shared_words() -> None:
    assert NO_OUTPUT == REPL["no_output"]


@needs_worker
@pytest.mark.parametrize("case", REPL["cases"], ids=lambda case: case["name"])
async def test_run_python_output_follows_the_shared_fixture(
    case: dict[str, Any],
) -> None:
    async with Worker() as worker:
        outputs = [await tool_output(worker, call["python"]) for call in case["calls"]]
    output = outputs[-1]

    if "output" in case:
        expected = for_python(case["output"])
        assert output == (REPL["no_output"] if expected == "$no_output" else expected)
    else:
        lines = output.split("\n")
        assert lines[0] == case["first_line"]
        assert lines[-1] == for_python(case["last_line"])


def test_the_worker_defaults_follow_the_shared_fixture() -> None:
    defaults = LIFECYCLE["defaults"]
    assert _driver.CALL_TIMEOUT == defaults["call_timeout"]
    assert _driver.INTERRUPT_GRACE == defaults["interrupt_grace"]
    assert _driver.IDLE_TIMEOUT == defaults["idle_timeout"]


@needs_worker
@pytest.mark.parametrize(
    "case", LIFECYCLE["failures"]["cases"], ids=lambda case: case["name"]
)
async def test_worker_failures_follow_the_shared_fixture(case: dict[str, Any]) -> None:
    seconds = LIFECYCLE["failures"]["seconds"]
    # A short grace keeps the unresponsive case quick; it is not in the text.
    async with Worker(call_timeout=seconds, interrupt_grace=1) as worker:
        output = await tool_output(worker, case["code"]["python"])

    expected = case["template"].format(
        seconds=seconds, **LIFECYCLE["substitutions"]["python"]
    )
    assert output == expected

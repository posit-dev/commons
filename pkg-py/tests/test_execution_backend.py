"""The exec-shaped seam the execution subsystem sits on.

Tests drive real subprocesses rather than mocks: the behaviours that matter
here (stdin delivery, output caps, kill escalation) are properties of process
handling, and a mock would only restate the implementation.
"""

from __future__ import annotations

import asyncio
import os
import sys
from typing import Any, cast

import pytest

from commons._execution._backend import (
    ExecBackend,
    ExecTimeoutError,
    LocalBackend,
    _terminate,
)


async def test_runs_a_command_and_returns_its_output() -> None:
    backend = LocalBackend()

    result = await backend.exec([sys.executable, "-c", "print('hello')"])

    assert result.returncode == 0
    assert result.stdout == "hello\n"
    assert result.stderr == ""


async def test_input_reaches_the_process_on_stdin() -> None:
    # Code goes in on stdin rather than as an argument: no escaping to get
    # wrong and no command-line length limit.
    backend = LocalBackend()

    result = await backend.exec(
        [sys.executable, "-c", "import sys; sys.stdout.write(sys.stdin.read())"],
        input="model-written code\n",
    )

    assert result.stdout == "model-written code\n"


async def test_the_process_starts_in_the_given_working_directory(tmp_path) -> None:
    backend = LocalBackend()

    result = await backend.exec(
        [sys.executable, "-c", "import os; print(os.getcwd())"],
        cwd=str(tmp_path),
    )

    assert result.stdout.strip() == os.path.realpath(tmp_path)


async def test_the_given_environment_replaces_the_parents_rather_than_extending_it(
    monkeypatch,
) -> None:
    # The parent holds credentials a child has no business seeing, and a
    # subprocess inherits the whole environment by default. Passing `env` has
    # to mean "exactly this", not "this as well".
    monkeypatch.setenv("COMMONS_TEST_SECRET", "sk-not-a-real-key")
    backend = LocalBackend()

    result = await backend.exec(
        [
            sys.executable,
            "-c",
            "import os; print(os.environ.get('COMMONS_TEST_SECRET'))",
        ],
        env={"PATH": os.environ["PATH"]},
    )

    assert result.stdout.strip() == "None"


NOISY = "for i in range(200): print(f'line-{i}:' + 'x' * 1000)"


async def test_output_past_the_cap_keeps_the_tail_and_the_process_still_finishes() -> (
    None
):
    # Killing the process on the cap would lose a result the code had already
    # computed, and simply not reading would deadlock it against a full pipe.
    # Keep draining, keep the most recent bytes, let it exit.
    backend = LocalBackend(output_limit=2000)

    result = await backend.exec([sys.executable, "-c", NOISY])

    assert result.returncode == 0
    assert len(result.stdout) <= 2000
    assert result.stdout.rstrip().endswith("x" * 100)
    assert "line-199:" in result.stdout
    assert "line-0:" not in result.stdout
    assert result.stdout_truncated


def _sleeper(sentinel: object, *, ignore_sigterm: bool = False) -> str:
    """Code that outlives its timeout and records the fact if it is allowed to."""
    guard = (
        "import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        if ignore_sigterm
        else ""
    )
    return f"{guard}import time; time.sleep(0.6); open({str(sentinel)!r}, 'w').close()"


async def test_a_call_past_the_timeout_raises_and_the_process_does_not_survive(
    tmp_path,
) -> None:
    sentinel = tmp_path / "survived"
    backend = LocalBackend()

    with pytest.raises(ExecTimeoutError):
        await backend.exec([sys.executable, "-c", _sleeper(sentinel)], timeout=0.15)

    await asyncio.sleep(0.8)
    assert not sentinel.exists()


async def test_a_process_that_handles_sigterm_gets_to_clean_up_first(tmp_path) -> None:
    # SIGKILL first would strand whatever the worker was in the middle of.
    # Ask politely, then insist.
    marker = tmp_path / "cleaned-up"
    code = (
        "import signal, sys, time\n"
        f"signal.signal(signal.SIGTERM, lambda *a: (open({str(marker)!r}, 'w').close(), sys.exit(0)))\n"
        "time.sleep(5)\n"
    )
    backend = LocalBackend()

    with pytest.raises(ExecTimeoutError):
        await backend.exec([sys.executable, "-c", code], timeout=0.15)

    assert marker.exists()


async def test_a_process_that_ignores_sigterm_is_killed_anyway(tmp_path) -> None:
    sentinel = tmp_path / "survived"
    backend = LocalBackend(terminate_grace=0.1)

    with pytest.raises(ExecTimeoutError):
        await backend.exec(
            [sys.executable, "-c", _sleeper(sentinel, ignore_sigterm=True)],
            timeout=0.15,
        )

    await asyncio.sleep(0.8)
    assert not sentinel.exists()


class _NeverReaped:
    """A process that takes its signals but whose exit is never observed.

    Stands in for the race where the child watcher misses the exit. There is
    no way to provoke that on demand, so this is the one place the suite
    substitutes a stand-in for a real process.
    """

    returncode: int | None = None

    def __init__(self) -> None:
        self.signals: list[str] = []

    def terminate(self) -> None:
        self.signals.append("term")

    def kill(self) -> None:
        self.signals.append("kill")

    async def wait(self) -> int:
        await asyncio.sleep(3600)
        return 0


async def test_terminate_gives_up_when_the_exit_is_never_reaped() -> None:
    process = _NeverReaped()

    await asyncio.wait_for(_terminate(cast(Any, process), 0.05), timeout=2)

    assert process.signals == ["term", "kill"]


async def test_input_to_a_process_that_never_reads_it_is_not_an_error() -> None:
    # A worker that dies during startup leaves nobody on the other end of the
    # pipe. That is a failed call to report, not an exception from the plumbing.
    backend = LocalBackend()

    result = await backend.exec(
        [sys.executable, "-c", "raise SystemExit(3)"],
        input="x" * (4 * 1024 * 1024),
    )

    assert result.returncode == 3


async def test_input_larger_than_the_pipe_buffer_arrives_in_full() -> None:
    # Handles cross this boundary, so delivery cannot quietly stop at whatever
    # the operating system's pipe buffer happens to be.
    backend = LocalBackend()
    payload = "y" * (4 * 1024 * 1024)

    result = await backend.exec(
        [sys.executable, "-c", "import sys; print(len(sys.stdin.read()))"],
        input=payload,
    )

    assert result.stdout.strip() == str(len(payload))


def test_the_local_backend_satisfies_the_backend_interface() -> None:
    # The annotation is the real assertion: pyrefly rejects an implementation
    # whose signature has drifted from the interface a container-hosted
    # backend would also have to meet.
    backend: ExecBackend = LocalBackend()

    assert isinstance(backend, ExecBackend)


async def test_the_timeout_still_applies_after_the_output_streams_close(
    tmp_path,
) -> None:
    # Reaching end-of-output is not the same as being finished. Code that
    # closes its streams and keeps running must still hit the deadline.
    sentinel = tmp_path / "survived"
    code = (
        "import os, time\n"
        "os.close(1); os.close(2)\n"
        f"time.sleep(0.6); open({str(sentinel)!r}, 'w').close()\n"
    )
    backend = LocalBackend()

    with pytest.raises(ExecTimeoutError):
        await backend.exec([sys.executable, "-c", code], timeout=0.15)

    await asyncio.sleep(0.8)
    assert not sentinel.exists()


async def test_cancelling_a_call_does_not_leave_the_process_running(tmp_path) -> None:
    # The driver cancels calls when a conversation goes away or the agent
    # shuts down. Whoever started the process has to be the one to end it.
    sentinel = tmp_path / "survived"
    backend = LocalBackend(terminate_grace=0.1)
    call = asyncio.create_task(backend.exec([sys.executable, "-c", _sleeper(sentinel)]))
    await asyncio.sleep(0.1)

    call.cancel()
    with pytest.raises(asyncio.CancelledError):
        await call

    await asyncio.sleep(0.8)
    assert not sentinel.exists()


async def test_cancellation_still_escalates_for_a_process_ignoring_sigterm(
    tmp_path,
) -> None:
    # The cancellation path does its waiting inside an except block, where an
    # await can be cut short. SIGKILL still has to land.
    sentinel = tmp_path / "survived"
    backend = LocalBackend(terminate_grace=0.1)
    call = asyncio.create_task(
        backend.exec([sys.executable, "-c", _sleeper(sentinel, ignore_sigterm=True)])
    )
    await asyncio.sleep(0.1)

    call.cancel()
    with pytest.raises(asyncio.CancelledError):
        await call

    await asyncio.sleep(0.8)
    assert not sentinel.exists()

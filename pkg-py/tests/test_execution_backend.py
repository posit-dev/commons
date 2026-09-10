"""The exec-shaped seam the execution subsystem sits on.

Tests drive real subprocesses rather than mocks: the behaviours that matter
here (stdin delivery, output caps, kill escalation) are properties of process
handling, and a mock would only restate the implementation.
"""

from __future__ import annotations

import asyncio
import os
import signal
import sys
from typing import Any, cast

import pytest

from commons._execution import _backend as backend_module
from commons._execution._backend import (
    DEFAULT_OUTPUT_LIMIT,
    TERMINATE_GRACE,
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
    """Code that outlives its timeout and records the fact if it is allowed to.

    The sleep sits well past the point where a working shutdown has killed
    the process, so a slow or loaded machine delays the kill into slack
    rather than into a false failure.
    """
    guard = (
        "import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        if ignore_sigterm
        else ""
    )
    return f"{guard}import time; time.sleep(1.5); open({str(sentinel)!r}, 'w').close()"


async def test_a_call_past_the_timeout_raises_and_the_process_does_not_survive(
    tmp_path,
) -> None:
    sentinel = tmp_path / "survived"
    backend = LocalBackend()

    with pytest.raises(ExecTimeoutError):
        await backend.exec([sys.executable, "-c", _sleeper(sentinel)], timeout=0.15)

    await asyncio.sleep(1.8)
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

    await asyncio.sleep(1.8)
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

    async def wait(self) -> int:
        await asyncio.sleep(3600)
        return 0


async def test_terminate_gives_up_when_the_exit_is_never_reaped(
    monkeypatch,
) -> None:
    process = _NeverReaped()

    def record_signals(process: Any, sig: signal.Signals) -> None:
        process.signals.append("term" if sig == signal.SIGTERM else "kill")

    monkeypatch.setattr(backend_module, "_signal_tree", record_signals)

    # The bound is two grace periods (SIGTERM, then SIGKILL), so 0.5s leaves
    # generous margin over the real 0.1s while still failing if the waits
    # stop honouring the grace they were given.
    await asyncio.wait_for(_terminate(cast(Any, process), 0.05), timeout=0.5)

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
        f"time.sleep(1.5); open({str(sentinel)!r}, 'w').close()\n"
    )
    backend = LocalBackend()

    with pytest.raises(ExecTimeoutError):
        await backend.exec([sys.executable, "-c", code], timeout=0.15)

    await asyncio.sleep(1.8)
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

    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_a_command_that_cannot_be_started_raises_os_error() -> None:
    # Nothing was spawned, so there is nothing to clean up: the failure
    # propagates as-is rather than being dressed up as an exec result.
    backend = LocalBackend()

    with pytest.raises(FileNotFoundError):
        await backend.exec(["/no/such/binary"])


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

    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_a_second_cancellation_cannot_abort_the_shutdown(tmp_path) -> None:
    # Shutdown is not the caller's to interrupt. A cancel landing while the
    # grace period is being awaited would otherwise skip SIGKILL and leave a
    # SIGTERM-ignoring child running.
    sentinel = tmp_path / "survived"
    backend = LocalBackend(terminate_grace=1.0)
    call = asyncio.create_task(
        backend.exec([sys.executable, "-c", _sleeper(sentinel, ignore_sigterm=True)])
    )
    await asyncio.sleep(0.1)

    call.cancel()
    # The SIGTERM grace runs for 1.0s from the first cancel, so the second
    # cancel at ~0.3s lands mid-shutdown with margin on both sides — the
    # race this test exists for must actually happen, or it quietly
    # degenerates into the plain cancellation test above.
    await asyncio.sleep(0.2)
    call.cancel()
    with pytest.raises(asyncio.CancelledError):
        await call

    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_omitting_the_environment_gives_the_child_an_empty_one(
    monkeypatch,
) -> None:
    # The parent holds credentials a child has no business seeing, so with no
    # allowlist in hand the default has to fail closed: no environment at
    # all, rather than the whole of the parent's.
    monkeypatch.setenv("COMMONS_TEST_SECRET", "sk-not-a-real-key")
    backend = LocalBackend()

    result = await backend.exec(
        [sys.executable, "-c", "import os; print(sorted(os.environ))"]
    )

    assert "COMMONS_TEST_SECRET" not in result.stdout


async def test_stderr_past_the_cap_keeps_the_tail_and_sets_its_own_flag() -> None:
    # The two streams are capped and flagged independently; a flag wired to
    # the wrong stream is invisible if only stdout is ever exercised.
    backend = LocalBackend(output_limit=2000)
    code = (
        "import sys\n"
        "for i in range(200):\n"
        "    sys.stderr.write(f'line-{i}:' + 'x' * 1000 + '\\n')\n"
    )

    result = await backend.exec([sys.executable, "-c", code])

    assert result.returncode == 0
    assert result.stdout == ""
    assert not result.stdout_truncated
    assert result.stderr_truncated
    assert len(result.stderr) <= 2000
    assert "line-199:" in result.stderr
    assert "line-0:" not in result.stderr


async def test_an_unexpected_error_mid_call_still_kills_the_process(
    tmp_path, monkeypatch
) -> None:
    # Timeout and cancellation are not the only ways out of a call. A pipe
    # failing mid-read (or any other surprise) must not leave the worker
    # running with nobody waiting on it.
    async def fail_read(
        stream: asyncio.StreamReader | None, limit: int
    ) -> tuple[bytes, bool]:
        raise RuntimeError("pipe failed mid-read")

    monkeypatch.setattr(backend_module, "_read_tail", fail_read)
    sentinel = tmp_path / "survived"
    backend = LocalBackend(terminate_grace=0.1)

    with pytest.raises(RuntimeError, match="pipe failed"):
        await backend.exec([sys.executable, "-c", _sleeper(sentinel)])

    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_input_that_cannot_be_encoded_still_kills_the_process(
    tmp_path,
) -> None:
    # Model-written text can contain unpaired surrogates, which fail at
    # encode time — after the child has already been spawned.
    sentinel = tmp_path / "survived"
    backend = LocalBackend(terminate_grace=0.1)

    with pytest.raises(UnicodeEncodeError):
        await backend.exec(
            [sys.executable, "-c", _sleeper(sentinel)], input="\ud800"
        )

    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_cancellation_during_the_timeout_shutdown_cannot_abort_it(
    tmp_path,
) -> None:
    # A cancel landing while the post-timeout shutdown is in flight must not
    # skip SIGKILL. The shutdown runs in its own task precisely so that it
    # outlives the call that started it.
    sentinel = tmp_path / "survived"
    backend = LocalBackend(terminate_grace=1.0)
    call = asyncio.create_task(
        backend.exec(
            [sys.executable, "-c", _sleeper(sentinel, ignore_sigterm=True)],
            timeout=0.1,
        )
    )
    # The timeout fires at ~0.1s and the SIGTERM grace then runs for 1.0s,
    # so a cancel at 0.5s lands in the middle of the shutdown with margin on
    # both sides — the race this test exists for must actually happen, or it
    # quietly degenerates into the plain timeout test above.
    await asyncio.sleep(0.5)

    call.cancel()
    with pytest.raises((asyncio.CancelledError, ExecTimeoutError)):
        await call

    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_reading_the_tail_of_a_missing_stream_is_empty() -> None:
    # exec always pipes both streams, so this guard is defensive; pin it so
    # it cannot be broken or deleted unnoticed.
    assert await backend_module._read_tail(None, 10) == (b"", False)


def test_the_defaults_are_the_documented_constants() -> None:
    # Every other test overrides these; pin the wiring itself.
    backend = LocalBackend()

    assert backend._output_limit == DEFAULT_OUTPUT_LIMIT
    assert backend._terminate_grace == TERMINATE_GRACE


async def test_concurrent_calls_on_one_backend_do_not_interfere(tmp_path) -> None:
    # The backend's one piece of shared state is the set of in-flight
    # shutdowns; one call timing out must not disturb another's result.
    sentinel = tmp_path / "survived"
    backend = LocalBackend(terminate_grace=0.1)
    slow = asyncio.create_task(
        backend.exec([sys.executable, "-c", _sleeper(sentinel)], timeout=0.15)
    )
    fast = asyncio.create_task(backend.exec([sys.executable, "-c", "print('ok')"]))

    with pytest.raises(ExecTimeoutError):
        await slow
    assert (await fast).stdout == "ok\n"

    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_aclose_waits_for_shutdowns_still_in_flight(tmp_path) -> None:
    # The escalation guarantee only holds while the event loop is running;
    # aclose is how a driver honours it while tearing down. A second cancel
    # is what leaves a shutdown running detached after the call has ended.
    sentinel = tmp_path / "survived"
    backend = LocalBackend(terminate_grace=1.0)
    call = asyncio.create_task(
        backend.exec([sys.executable, "-c", _sleeper(sentinel, ignore_sigterm=True)])
    )
    await asyncio.sleep(0.1)

    call.cancel()
    await asyncio.sleep(0.1)
    call.cancel()
    with pytest.raises(asyncio.CancelledError):
        await call

    assert backend._shutdowns
    await backend.aclose()
    assert not backend._shutdowns

    await asyncio.sleep(1.8)
    assert not sentinel.exists()


@pytest.mark.skipif(os.name != "posix", reason="os.fork is POSIX-only")
async def test_a_workers_own_children_do_not_survive_the_shutdown(tmp_path) -> None:
    # The escalation signals the worker's whole process group: code that
    # forks a child of its own cannot strand it, and cannot hold the output
    # pipes open past the worker's own exit.
    sentinel = tmp_path / "survived"
    code = (
        "import os, time\n"
        "if os.fork() == 0:\n"
        f"    time.sleep(1.5); open({str(sentinel)!r}, 'w').close(); os._exit(0)\n"
        "time.sleep(5)\n"
    )
    backend = LocalBackend(terminate_grace=0.1)

    with pytest.raises(ExecTimeoutError):
        await backend.exec([sys.executable, "-c", code], timeout=0.15)

    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_both_streams_past_the_cap_are_capped_independently() -> None:
    # The two streams keep separate buffers and flags even when both blow
    # past the cap in the same call.
    backend = LocalBackend(output_limit=2000)
    code = (
        "import sys\n"
        "for i in range(200):\n"
        "    sys.stdout.write(f'o-{i}:' + 'x' * 1000 + '\\n')\n"
        "    sys.stderr.write(f'e-{i}:' + 'y' * 1000 + '\\n')\n"
    )

    result = await backend.exec([sys.executable, "-c", code])

    assert result.returncode == 0
    assert result.stdout_truncated
    assert result.stderr_truncated
    assert len(result.stdout) <= 2000
    assert len(result.stderr) <= 2000
    assert "o-199:" in result.stdout
    assert "o-0:" not in result.stdout
    assert "e-199:" in result.stderr
    assert "e-0:" not in result.stderr

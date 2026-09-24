"""The seam the execution subsystem sits on: starting and ending a worker.

Tests drive real subprocesses rather than mocks: the behaviours that matter
here (the channel, the environment, kill escalation) are properties of
process handling, and a mock would only restate the implementation. Each
test hands the backend a small script of its own in place of the worker
entry point, so the process does exactly what the test needs of it.
"""

from __future__ import annotations

import asyncio
import os
import signal
import time
from pathlib import Path
from typing import Any, cast

import pytest

from commons._execution import _backend as backend_module
from commons._execution._backend import (
    STDERR_TAIL,
    TERMINATE_GRACE,
    ExecBackend,
    LocalBackend,
    LocalSession,
    WorkerSession,
    _read_tail,
    _terminate,
)
from commons._execution._sandbox import protection_mode

try:
    protection_mode()
except RuntimeError:
    pytestmark = pytest.mark.skip(reason="this host cannot sandbox the worker")


def backend_running(tmp_path: Path, code: str, **kwargs: Any) -> LocalBackend:
    """A backend whose worker runs ``code`` in place of the real entry point."""
    script = tmp_path / "worker.py"
    script.write_text(code)
    return LocalBackend(worker_script=script, **kwargs)


async def wait_for_file(path: Path, timeout: float = 10.0) -> None:
    """Block until the child creates ``path``; polling, since it is another process."""
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() > deadline:
            raise AssertionError(f"{path.name} did not appear within {timeout}s")
        await asyncio.sleep(0.01)


def sleeper(sentinel: Path, ready: Path, *, ignore_sigterm: bool = False) -> str:
    """A worker that announces itself, then records it if it outlives its close.

    The sleep sits well past the point where a working shutdown has killed
    the process, so a slow machine delays the kill into slack rather than
    into a false failure.
    """
    guard = (
        "import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        if ignore_sigterm
        else ""
    )
    return (
        f"{guard}import time\n"
        f"open({str(ready)!r}, 'w').close()\n"
        f"time.sleep(1.5); open({str(sentinel)!r}, 'w').close()\n"
    )


async def test_the_channel_is_the_workers_stdin_and_stdout(tmp_path) -> None:
    backend = backend_running(
        tmp_path, "import sys\nsys.stdout.write(sys.stdin.readline().upper())\n"
    )
    session = await backend.start(network="none")
    session.stdin.write(b"model-written code\n")
    await session.stdin.drain()
    assert await session.stdout.readline() == b"MODEL-WRITTEN CODE\n"
    await session.close()


async def test_the_worker_starts_in_a_scratch_directory_that_close_removes(
    tmp_path,
) -> None:
    backend = backend_running(tmp_path, "import os\nprint(os.getcwd())\n")
    session = await backend.start(network="none")
    assert isinstance(session, LocalSession)
    cwd = (await session.stdout.readline()).decode().strip()
    assert cwd == os.path.realpath(session.scratch)
    assert cwd != os.path.realpath(tmp_path)
    await session.close()
    assert not os.path.exists(session.scratch)


async def test_the_worker_gets_the_allowlisted_environment_not_the_parents(
    tmp_path, monkeypatch
) -> None:
    # The parent holds credentials a child has no business seeing, and a
    # subprocess inherits the whole environment by default.
    monkeypatch.setenv("COMMONS_TEST_SECRET", "sk-not-a-real-key")
    backend = backend_running(
        tmp_path,
        "import os\n"
        "print(os.environ.get('COMMONS_TEST_SECRET'), os.path.realpath(os.environ['HOME']) == os.getcwd())\n",
    )
    session = await backend.start(network="none")
    assert (await session.stdout.readline()).split() == [b"None", b"True"]
    await session.close()


async def test_the_worker_is_told_its_network_and_protection(tmp_path) -> None:
    backend = backend_running(tmp_path, "import sys\nprint(sys.argv[1:])\n")
    session = await backend.start(network="full")
    line = (await session.stdout.readline()).decode()
    assert line.strip() == repr(["full", protection_mode()])
    await session.close()


async def test_interrupt_raises_keyboard_interrupt_in_the_worker(tmp_path) -> None:
    ready = tmp_path / "ready"
    backend = backend_running(
        tmp_path,
        "import time\n"
        "try:\n"
        f"    open({str(ready)!r}, 'w').close(); time.sleep(30)\n"
        "except KeyboardInterrupt:\n"
        "    print('interrupted', flush=True)\n",
    )
    session = await backend.start(network="none")
    await wait_for_file(ready)
    session.interrupt()
    line = await asyncio.wait_for(session.stdout.readline(), 5)
    assert line == b"interrupted\n"
    await session.close()


async def test_a_worker_that_handles_sigterm_gets_to_clean_up_first(tmp_path) -> None:
    # SIGKILL first would strand whatever the worker was in the middle of.
    # Ask politely, then insist.
    marker = tmp_path / "cleaned-up"
    ready = tmp_path / "ready"
    backend = backend_running(
        tmp_path,
        "import signal, sys, time\n"
        f"signal.signal(signal.SIGTERM, lambda *a: (open({str(marker)!r}, 'w').close(), sys.exit(0)))\n"
        f"open({str(ready)!r}, 'w').close()\n"
        "time.sleep(5)\n",
    )
    session = await backend.start(network="none")
    await wait_for_file(ready)
    await session.close()
    assert marker.exists()


async def test_a_worker_that_ignores_sigterm_is_killed_anyway(tmp_path) -> None:
    sentinel, ready = tmp_path / "survived", tmp_path / "ready"
    backend = backend_running(
        tmp_path, sleeper(sentinel, ready, ignore_sigterm=True), terminate_grace=0.1
    )
    session = await backend.start(network="none")
    await wait_for_file(ready)
    await session.close()
    assert session.returncode is not None
    await asyncio.sleep(1.8)
    assert not sentinel.exists()


@pytest.mark.skipif(os.name != "posix", reason="os.fork is POSIX-only")
async def test_a_workers_own_children_do_not_survive_the_close(tmp_path) -> None:
    # The escalation signals the worker's whole process group: code that
    # forks a child of its own cannot strand it.
    sentinel, ready = tmp_path / "survived", tmp_path / "ready"
    backend = backend_running(
        tmp_path,
        "import os, time\n"
        "if os.fork() == 0:\n"
        f"    time.sleep(1.5); open({str(sentinel)!r}, 'w').close(); os._exit(0)\n"
        f"open({str(ready)!r}, 'w').close()\n"
        "time.sleep(5)\n",
        terminate_grace=0.1,
    )
    session = await backend.start(network="none")
    await wait_for_file(ready)
    await session.close()
    await asyncio.sleep(1.8)
    assert not sentinel.exists()


@pytest.mark.skipif(os.name != "posix", reason="os.fork is POSIX-only")
async def test_closing_a_dead_worker_still_kills_its_children(tmp_path) -> None:
    # The leader's exit leaves its process group behind; the close takes it
    # anyway rather than skipping a worker that is already gone. The child
    # lets go of the pipes, as the real worker's fds are sinks, so that the
    # leader's exit is observed while the child still runs.
    sentinel = tmp_path / "survived"
    backend = backend_running(
        tmp_path,
        "import os, time\n"
        "if os.fork() == 0:\n"
        "    sink = os.open(os.devnull, os.O_RDWR)\n"
        "    for fd in (0, 1, 2):\n"
        "        os.dup2(sink, fd)\n"
        f"    time.sleep(1.5); open({str(sentinel)!r}, 'w').close(); os._exit(0)\n",
    )
    session = await backend.start(network="none")
    assert isinstance(session, LocalSession)
    await session.process.wait()
    await session.close()
    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_a_cancelled_close_still_kills_the_worker_and_reraises(tmp_path) -> None:
    # Shutdown is not the caller's to interrupt: a cancel arriving while the
    # SIGTERM grace is awaited would otherwise skip SIGKILL. The caller is
    # still told it was cancelled.
    sentinel, ready = tmp_path / "survived", tmp_path / "ready"
    backend = backend_running(
        tmp_path, sleeper(sentinel, ready, ignore_sigterm=True), terminate_grace=1.0
    )
    session = await backend.start(network="none")
    await wait_for_file(ready)
    closing = asyncio.ensure_future(session.close())
    # The grace runs for 1.0s, so a cancel at 0.2s arrives mid-shutdown.
    await asyncio.sleep(0.2)
    closing.cancel()
    with pytest.raises(asyncio.CancelledError):
        await closing
    assert backend._shutdowns
    await backend.aclose()
    assert not backend._shutdowns
    assert session.returncode is not None
    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_close_is_safe_to_call_twice(tmp_path) -> None:
    backend = backend_running(tmp_path, "import time\ntime.sleep(30)\n")
    session = await backend.start(network="none")
    await asyncio.gather(session.close(), session.close())
    await session.close()
    assert session.returncode is not None


async def test_cancelling_a_start_leaves_no_worker_behind(tmp_path) -> None:
    sentinel = tmp_path / "survived"
    backend = backend_running(
        tmp_path,
        f"import time\ntime.sleep(1.5); open({str(sentinel)!r}, 'w').close()\n",
        terminate_grace=0.1,
    )
    starting = asyncio.ensure_future(backend.start(network="none"))
    await asyncio.sleep(0)
    starting.cancel()
    with pytest.raises(asyncio.CancelledError):
        await starting
    await backend.aclose()
    await asyncio.sleep(1.8)
    assert not sentinel.exists()


async def test_stderr_keeps_the_tail_of_what_the_worker_wrote(tmp_path) -> None:
    backend = backend_running(
        tmp_path,
        "import sys\n"
        "for i in range(200):\n"
        "    sys.stderr.write(f'line-{i}:' + 'x' * 1000 + '\\n')\n",
    )
    session = await backend.start(network="none")
    assert isinstance(session, LocalSession)
    await session.process.wait()
    await session.close()
    tail = await session.stderr()
    assert len(tail) <= STDERR_TAIL
    assert "line-199:" in tail
    assert "line-0:" not in tail


async def test_reading_a_tail_keeps_the_last_bytes_and_flags_the_cut() -> None:
    stream = asyncio.StreamReader()
    stream.feed_data(b"a" * 5000 + b"end")
    stream.feed_eof()
    assert await _read_tail(stream, 10) == (b"aaaaaaaend", True)


async def test_reading_the_tail_of_a_missing_stream_is_empty() -> None:
    assert await _read_tail(None, 10) == (b"", False)


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


async def test_terminate_gives_up_when_the_exit_is_never_reaped(monkeypatch) -> None:
    process = _NeverReaped()

    def record_signals(process: Any, sig: signal.Signals) -> None:
        process.signals.append("term" if sig == signal.SIGTERM else "kill")

    monkeypatch.setattr(backend_module, "_signal_tree", record_signals)

    # The bound is two grace periods (SIGTERM, then SIGKILL), so 0.5s leaves
    # generous margin over the real 0.1s while still failing if the waits
    # stop honouring the grace they were given.
    await asyncio.wait_for(_terminate(cast(Any, process), 0.05), timeout=0.5)

    assert process.signals == ["term", "kill"]


async def test_the_local_backend_satisfies_the_backend_interface(tmp_path) -> None:
    # The annotations are the real assertion: pyrefly rejects an
    # implementation whose signature has drifted from the interface a
    # container-hosted backend would also have to meet.
    backend: ExecBackend = backend_running(tmp_path, "")
    session: WorkerSession = await backend.start(network="none")
    assert isinstance(backend, ExecBackend)
    assert isinstance(session, WorkerSession)
    await session.close()


def test_the_default_grace_is_the_documented_constant() -> None:
    assert LocalBackend()._terminate_grace == TERMINATE_GRACE


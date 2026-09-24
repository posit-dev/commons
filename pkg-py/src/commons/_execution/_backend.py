"""The seam between the execution driver and whatever runs the worker.

The driver starts a worker session through ``ExecBackend.start`` and talks to
it over the session's pipes. Everything about where the process runs belongs
to the backend: its scratch directory, its environment, how much protection
it gets, how it is signalled, and how it is shut down. A container-hosted
backend is then another implementation of this, not an edit to the driver.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import shutil
import signal
import tempfile
from collections.abc import Coroutine
from pathlib import Path
from typing import Any, Literal, Protocol, runtime_checkable

from ._env import worker_command, worker_env
from ._protocol import STREAM_LIMIT
from ._sandbox import needs_single_thread, protection_mode

__all__ = ["ExecBackend", "LocalBackend", "LocalSession", "Network", "WorkerSession"]

Network = Literal["none", "full"]

# How long to be patient with a process being shut down: first for it to
# honour SIGTERM, then for its exit to be observed after SIGKILL.
TERMINATE_GRACE = 2.0

# Kept from the worker's stderr for diagnosing a failed start. The worker
# points fd 2 at a sink once it is up, so only startup output is written.
STDERR_TAIL = 8 * 1024

WORKER_SCRIPT = Path(__file__).parent / "_runtime" / "_worker.py"


@runtime_checkable
class WorkerSession(Protocol):
    """One running worker process, as the driver sees it.

    ``stdin`` and ``stdout`` are the protocol channel. ``close()`` is the
    only way the session ends early, and it is safe to call more than once.
    """

    @property
    def stdin(self) -> asyncio.StreamWriter: ...

    @property
    def stdout(self) -> asyncio.StreamReader: ...

    @property
    def returncode(self) -> int | None:
        """The exit status, or ``None`` while the worker runs."""
        ...

    def interrupt(self) -> None:
        """Raise ``KeyboardInterrupt`` in the worker's call, and its children's."""
        ...

    async def close(self) -> None:
        """End the worker and everything it spawned, then remove its files.

        The shutdown runs to completion even if the caller is cancelled
        while it waits; the cancellation still reaches the caller.
        """
        ...

    async def stderr(self) -> str:
        """The tail of what the worker wrote to stderr before it went quiet.

        Waits for the stream to end, so call it after ``close()``.
        """
        ...


@runtime_checkable
class ExecBackend(Protocol):
    """What the driver needs from whatever runs the worker."""

    async def start(self, *, network: Network) -> WorkerSession:
        """Start a worker with the given network access and return its session.

        Raises ``OSError`` if the process cannot be started at all. A
        cancelled start leaves no process behind.
        """
        ...

    async def aclose(self) -> None:
        """Wait for every shutdown still in flight."""
        ...


async def _read_tail(
    stream: asyncio.StreamReader | None, limit: int
) -> tuple[bytes, bool]:
    """Drain ``stream``, keeping only its last ``limit`` bytes.

    Draining is the point: a process whose output nobody reads blocks forever
    on a full pipe. Dropping the head rather than the tail keeps the part of
    the output most likely to hold the result.
    """
    if stream is None:
        return b"", False
    kept = bytearray()
    truncated = False
    while chunk := await stream.read(64 * 1024):
        kept += chunk
        # Trim only once the buffer is well past the cap, so staying under
        # it costs no per-chunk copying; the trim after the loop restores
        # the exact "last limit bytes" boundary.
        if len(kept) > 2 * limit:
            del kept[: len(kept) - limit]
            truncated = True
    if len(kept) > limit:
        del kept[: len(kept) - limit]
        truncated = True
    return bytes(kept), truncated


class LocalBackend:
    """Runs the worker as a sandboxed child of this process.

    How much protection the worker gets is decided at construction (see
    ``protection_mode``), so a host commons cannot protect fails here, ahead
    of any model asking to run code. There is deliberately no protection
    argument: the only way to accept weaker protection is the environment
    opt-in that ``protection_mode()`` consults.

    The lifecycle is POSIX-shaped. On Windows ``terminate()`` and ``kill()``
    are both ``TerminateProcess``, so the grace window does not exist, and
    ``protection_mode()`` refuses the host anyway.
    """

    def __init__(
        self,
        *,
        terminate_grace: float = TERMINATE_GRACE,
        worker_script: Path = WORKER_SCRIPT,
    ) -> None:
        """Decide the protection mode and configure shutdown patience.

        ``terminate_grace`` is how long to wait for SIGTERM to be honoured
        before escalating to SIGKILL, and again for the exit to be observed
        afterwards. ``worker_script`` is the entry point the process runs;
        leave it at its default outside the tests.
        """
        self._protection = protection_mode()
        self._terminate_grace = terminate_grace
        self._worker_script = worker_script
        # Shutdowns outlive the call that started them, so they need an owner
        # that keeps them from being garbage-collected mid-escalation.
        self._shutdowns: set[asyncio.Task[None]] = set()

    async def start(self, *, network: Network) -> LocalSession:
        scratch = tempfile.mkdtemp(prefix="commons-worker-")
        spawn = asyncio.ensure_future(
            asyncio.create_subprocess_exec(
                *worker_command(str(self._worker_script), network, self._protection),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=scratch,
                env=worker_env(scratch, single_thread=needs_single_thread()),
                limit=STREAM_LIMIT,
                # Session leader, so signals can take the worker's whole
                # process group rather than just the worker (see _signal_tree).
                start_new_session=True,
            )
        )
        try:
            # Shielded: a process created while this start is being
            # cancelled must end up tracked and killed, never leaked.
            process = await asyncio.shield(spawn)
        except asyncio.CancelledError:
            self._track(self._reap_spawn(spawn, scratch))
            raise
        except BaseException:
            shutil.rmtree(scratch, ignore_errors=True)
            raise
        return LocalSession(self, process, scratch)

    async def aclose(self) -> None:
        """Wait for any shutdowns still in flight.

        The escalation guarantee, that a cancelled call cannot leave a
        SIGTERM-ignoring child alive, holds only while the event loop is
        running. A driver that is tearing down should call this before the
        loop closes. Each shutdown is bounded by two grace periods, so this
        returns in bounded time.
        """
        await asyncio.gather(*list(self._shutdowns), return_exceptions=True)

    def _track(self, work: Coroutine[Any, Any, None]) -> asyncio.Task[None]:
        task = asyncio.ensure_future(work)
        self._shutdowns.add(task)
        task.add_done_callback(self._shutdowns.discard)
        return task

    async def _reap_spawn(
        self, spawn: asyncio.Future[asyncio.subprocess.Process], scratch: str
    ) -> None:
        """Kill a child whose start was cancelled mid-spawn, and remove its files."""
        try:
            process = await spawn
        except Exception:  # noqa: BLE001 - a failed spawn has no child to kill
            process = None
        if process is not None:
            await _terminate(process, self._terminate_grace)
        shutil.rmtree(scratch, ignore_errors=True)


class LocalSession:
    """A worker running as a child process, with its scratch directory."""

    def __init__(
        self, backend: LocalBackend, process: asyncio.subprocess.Process, scratch: str
    ) -> None:
        assert process.stdin is not None and process.stdout is not None  # piped
        self.process = process
        self.scratch = scratch
        self._backend = backend
        self._stdin = process.stdin
        self._stdout = process.stdout
        self._drain = asyncio.ensure_future(_read_tail(process.stderr, STDERR_TAIL))
        self._closing: asyncio.Task[None] | None = None

    @property
    def stdin(self) -> asyncio.StreamWriter:
        return self._stdin

    @property
    def stdout(self) -> asyncio.StreamReader:
        return self._stdout

    @property
    def returncode(self) -> int | None:
        return self.process.returncode

    def interrupt(self) -> None:
        # The whole group, as in the shutdown: a call blocked in
        # subprocess.run() must take its children with it, or they outlive
        # the timeout the interrupt enforces.
        with contextlib.suppress(ProcessLookupError):
            _signal_tree(self.process, signal.SIGINT)

    async def close(self) -> None:
        if self._closing is None:
            self._closing = self._backend._track(self._finish())
        await asyncio.shield(self._closing)

    async def stderr(self) -> str:
        try:
            tail, _ = await asyncio.wait_for(
                asyncio.shield(self._drain), self._backend._terminate_grace
            )
        except TimeoutError:
            return ""
        return tail.decode(errors="replace").strip()

    async def _finish(self) -> None:
        """The bounded kill, then the cleanup."""
        process = self.process
        if process.returncode is not None and os.name == "posix":
            # The leader is dead, so _terminate below will not signal
            # anything, but its process group may not be: a background
            # child outlives the crash that took the worker.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
        await _terminate(process, self._backend._terminate_grace)
        # The drain ends at EOF, which the kill forces; the bound covers a
        # descendant that kept the pipe open.
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(
                asyncio.shield(self._drain), self._backend._terminate_grace
            )
        # The process is gone, so its files can be removed; model code may
        # have left some unreadable, which is not a reason to fail.
        shutil.rmtree(self.scratch, ignore_errors=True)


def _signal_tree(process: asyncio.subprocess.Process, sig: signal.Signals) -> None:
    """Signal the child's whole process group, falling back to the child alone.

    The child is spawned as a session leader, so its process group is its own
    PID and everything it forked along the way comes with it: a worker that
    spawned children of its own cannot strand them, or keep the output pipes
    open past its own exit. Off POSIX there are no process groups, so only
    the direct child is signalled.
    """
    if os.name == "posix":
        try:
            os.killpg(process.pid, sig)
            return
        except ProcessLookupError:
            pass  # The group is gone or never had a session; signal directly.
    if sig == signal.SIGTERM:
        process.terminate()
    elif sig == signal.SIGINT:
        process.send_signal(sig)
    else:
        process.kill()


async def _terminate(process: asyncio.subprocess.Process, grace: float) -> None:
    """Ask the process to exit, then insist.

    Signals go to the child's process group (see ``_signal_tree``), so the
    escalation covers everything the worker spawned, not just the worker.
    """
    if process.returncode is not None:
        return
    _signal_tree(process, signal.SIGTERM)
    try:
        await asyncio.wait_for(asyncio.shield(process.wait()), grace)
        return
    except TimeoutError:
        pass
    _signal_tree(process, signal.SIGKILL)
    # The exit can go unobserved if the child watcher misses it, and a killed
    # process is gone whether or not we see it go. Wait, but not forever.
    try:
        await asyncio.wait_for(asyncio.shield(process.wait()), grace)
    except TimeoutError:
        pass

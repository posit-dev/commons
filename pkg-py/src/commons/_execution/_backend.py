"""The seam between the execution driver and whatever runs the worker.

Everything above this line talks to a single ``exec``-shaped call, so a
container-hosted backend can be added later as another implementation rather
than as an edit to the driver.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import signal
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

__all__ = ["ExecBackend", "ExecResult", "ExecTimeoutError", "LocalBackend"]

# Enough for a generous amount of printed output without letting a runaway
# loop hold the whole of it in memory.
DEFAULT_OUTPUT_LIMIT = 1024 * 1024

# How long to be patient with a process being shut down: first for it to
# honour SIGTERM, then for its exit to be observed after SIGKILL.
TERMINATE_GRACE = 2.0


class ExecTimeoutError(TimeoutError):
    """The command ran past its deadline and was killed."""


@dataclass(frozen=True, kw_only=True)
class ExecResult:
    returncode: int
    stdout: str
    stderr: str
    stdout_truncated: bool = False
    stderr_truncated: bool = False


@runtime_checkable
class ExecBackend(Protocol):
    """What the driver needs from whatever runs the worker.

    Kept to one call so that hosting the worker somewhere else — a container,
    say — is a new implementation of this, not a change to the driver.
    """

    async def exec(
        self,
        cmd: Sequence[str],
        *,
        input: str | None = None,
        cwd: str | None = None,
        env: Mapping[str, str] | None = None,
        timeout: float | None = None,
    ) -> ExecResult:
        """Run ``cmd``, feeding ``input`` on stdin, and collect its output.

        ``env`` replaces the parent's environment outright rather than
        extending it, and omitting it gives the child an empty one: the
        parent holds credentials the child has no business seeing, so the
        default fails closed.

        ``input`` is encoded as UTF-8, and output is decoded as UTF-8 with
        invalid bytes replaced. Both are the contract every backend
        implements, not a local choice.

        ``input`` is buffered whole in the calling process until the child
        reads it, so bounding its size is the caller's responsibility.

        Raises ``ExecTimeoutError`` if ``timeout`` passes before the command
        finishes, having first made sure the process is gone. A command that
        cannot be started at all raises the underlying ``OSError`` (usually
        ``FileNotFoundError``) instead.
        """
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
    """Runs the worker as a child of this process, with no isolation.

    The lifecycle below is POSIX-shaped. On Windows ``terminate()`` and
    ``kill()`` are both ``TerminateProcess`` — the grace window does not
    exist — and an empty environment can keep the child from spawning at
    all (``SystemRoot`` is required). What Windows should do instead —
    refuse, or run with weaker guarantees and a warning — is the sandbox
    unit's decision, not this class's; ``sandbox_capabilities()`` in
    ``pkg-r`` is the existing template for reporting "not sandboxable".
    """

    def __init__(
        self,
        *,
        output_limit: int = DEFAULT_OUTPUT_LIMIT,
        terminate_grace: float = TERMINATE_GRACE,
    ) -> None:
        """Configure output retention and shutdown patience.

        ``output_limit`` caps how many bytes are kept from each of stdout
        and stderr; past the cap the oldest bytes are dropped, keeping the
        tail. ``terminate_grace`` is how long to wait for SIGTERM to be
        honoured before escalating to SIGKILL, and again for the exit to be
        observed afterwards.
        """
        self._output_limit = output_limit
        self._terminate_grace = terminate_grace
        # Shutdowns outlive the call that started them, so they need an owner
        # that keeps them from being garbage-collected mid-escalation.
        self._shutdowns: set[asyncio.Task[None]] = set()

    async def _collect(
        self, process: asyncio.subprocess.Process
    ) -> tuple[tuple[bytes, bool], tuple[bytes, bool]]:
        """Drain both streams, then wait for the process to actually exit.

        Reaching end-of-output is not the same as being finished: code can
        close its streams and keep running. Both halves sit inside the
        caller's deadline so that neither can outlast it.
        """
        streams = await asyncio.gather(
            _read_tail(process.stdout, self._output_limit),
            _read_tail(process.stderr, self._output_limit),
        )
        await process.wait()
        return streams[0], streams[1]

    async def exec(
        self,
        cmd: Sequence[str],
        *,
        input: str | None = None,
        cwd: str | None = None,
        env: Mapping[str, str] | None = None,
        timeout: float | None = None,
    ) -> ExecResult:
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd,
            env={} if env is None else dict(env),
            # Session leader, so shutdown signals can take the worker's whole
            # process group rather than just the worker (see _signal_tree).
            start_new_session=True,
        )
        try:
            if process.stdin is not None:
                if input is not None:
                    process.stdin.write(input.encode())
                process.stdin.close()
            stdout, stderr = await asyncio.wait_for(self._collect(process), timeout)
        except TimeoutError:
            await self._shutdown(process)
            raise ExecTimeoutError(
                f"the command exceeded its {timeout}-second time limit"
            ) from None
        except BaseException:
            # an escape hatch to make sure we properly shutdown the process
            # regardless of how it exits
            await self._shutdown(process)
            raise
        # _collect awaited wait(), so the return code is known here; if that
        # invariant ever breaks, fail loudly rather than report "succeeded".
        assert process.returncode is not None
        return ExecResult(
            returncode=process.returncode,
            stdout=stdout[0].decode(errors="replace"),
            stderr=stderr[0].decode(errors="replace"),
            stdout_truncated=stdout[1],
            stderr_truncated=stderr[1],
        )

    async def aclose(self) -> None:
        """Wait for any shutdowns still in flight.

        The escalation guarantee — that a cancelled call cannot leave a
        SIGTERM-ignoring child alive — holds only while the event loop is
        running. A driver that is tearing down should call this before the
        loop closes, so a last-minute cancellation does not strand a
        shutdown mid-escalation. Each shutdown is bounded by two grace
        periods, so this returns in bounded time.
        """
        await asyncio.gather(*list(self._shutdowns), return_exceptions=True)

    async def _shutdown(self, process: asyncio.subprocess.Process) -> None:
        """Terminate ``process``, outliving cancellation of the caller.

        Shutdown runs in its own task to ensure it is actually performed 
        (e.g. cancellation arriving while a shutdown is already in process
        doesn't stop the shutdown itself). It must not be possible to
        leave a SIGTERM-ignoring child alive by cancelling at the wrong
        moment.
        """
        shutdown = asyncio.ensure_future(_terminate(process, self._terminate_grace))
        self._shutdowns.add(shutdown)
        shutdown.add_done_callback(self._shutdowns.discard)
        with contextlib.suppress(asyncio.CancelledError):
            await asyncio.shield(shutdown)


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

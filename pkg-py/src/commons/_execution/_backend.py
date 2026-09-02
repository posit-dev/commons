"""The seam between the execution driver and whatever runs the worker.

Everything above this line talks to a single ``exec``-shaped call, so a
container-hosted backend can be added later as another implementation rather
than as an edit to the driver.
"""

from __future__ import annotations

import asyncio
import contextlib
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


@dataclass(frozen=True)
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

        Raises ``ExecTimeoutError`` if ``timeout`` passes before the command
        finishes, having first made sure the process is gone.
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
    while True:
        chunk = await stream.read(64 * 1024)
        if not chunk:
            return bytes(kept), truncated
        kept += chunk
        if len(kept) > limit:
            del kept[: len(kept) - limit]
            truncated = True


class LocalBackend:
    """Runs the worker as a child of this process, with no isolation."""

    def __init__(
        self,
        output_limit: int = DEFAULT_OUTPUT_LIMIT,
        terminate_grace: float = TERMINATE_GRACE,
    ) -> None:
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
            env=None if env is None else dict(env),
        )
        if process.stdin is not None:
            if input is not None:
                process.stdin.write(input.encode())
            process.stdin.close()
        try:
            stdout, stderr = await asyncio.wait_for(self._collect(process), timeout)
        except TimeoutError:
            await _terminate(process, self._terminate_grace)
            raise ExecTimeoutError(
                f"the command exceeded its {timeout}-second time limit"
            ) from None
        except asyncio.CancelledError:
            # Whoever started the process ends it. A cancelled call that left
            # the worker running would keep holding the parent's file
            # descriptors and go on burning CPU with nobody waiting on it.
            #
            # Shutdown runs in its own task so that a second cancellation
            # stops us waiting on it without stopping the escalation itself;
            # a caller cancelling twice must not be able to leave a
            # SIGTERM-ignoring child alive.
            shutdown = asyncio.ensure_future(_terminate(process, self._terminate_grace))
            self._shutdowns.add(shutdown)
            shutdown.add_done_callback(self._shutdowns.discard)
            with contextlib.suppress(asyncio.CancelledError):
                await asyncio.shield(shutdown)
            raise
        return ExecResult(
            returncode=process.returncode or 0,
            stdout=stdout[0].decode(errors="replace"),
            stderr=stderr[0].decode(errors="replace"),
            stdout_truncated=stdout[1],
            stderr_truncated=stderr[1],
        )


async def _terminate(process: asyncio.subprocess.Process, grace: float) -> None:
    """Ask the process to exit, then insist."""
    if process.returncode is not None:
        return
    process.terminate()
    try:
        await asyncio.wait_for(asyncio.shield(process.wait()), grace)
        return
    except TimeoutError:
        pass
    process.kill()
    # The exit can go unobserved if the child watcher misses it, and a killed
    # process is gone whether or not we see it go. Wait, but not forever.
    try:
        await asyncio.wait_for(asyncio.shield(process.wait()), grace)
    except TimeoutError:
        pass

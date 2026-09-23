"""The worker's lifecycle: lazy spawn, one call at a time, timeouts, and the idle reap.

A ``Worker`` owns one persistent Python session in a child process. No
process exists until the first call; one that sits idle is closed, and the
next call spawns a fresh one. Calls are serialized through an
``asyncio.Lock`` — the single session can only run one piece of code at a
time — and a call that outruns its time limit is interrupted first and
killed only if the interrupt goes unanswered, because the two outcomes mean
different things: an interrupted session keeps its variables, a restarted
one has lost them.

``run_r_tool()`` and ``worker_await()`` in pkg-r/R/run-r.R implement the
same lifecycle over callr's promise chain.
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import os
import shutil
import signal
import tempfile
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Self

from .._handles import HandleStore
from . import _protocol
from ._backend import TERMINATE_GRACE, _terminate
from ._env import worker_command, worker_env
from ._protocol import Call, Error, Ready, Result
from ._sandbox import needs_single_thread, protection_mode

__all__ = ["Failure", "Worker"]

CALL_TIMEOUT = 60.0
IDLE_TIMEOUT = 600.0

# How long an interrupted worker gets to answer before it is killed. The
# interrupt raises KeyboardInterrupt in the worker's call, so a responsive
# one answers almost immediately.
INTERRUPT_GRACE = 5.0

# Startup is interpreter boot plus the sandbox engage, neither of which
# should take seconds; the bound exists so a wedged spawn fails the call
# rather than hanging it.
SPAWN_TIMEOUT = 30.0

# Kept from the worker's stderr for diagnosing a failed start. The worker
# points fd 2 at a sink once it is up, so only startup output is written.
_STDERR_TAIL = 8 * 1024

_WORKER_SCRIPT = Path(__file__).parent / "_runtime" / "_worker.py"

Network = Literal["none", "full"]


@dataclass(frozen=True, kw_only=True)
class Failure:
    """A call that never got an answer from the worker.

    ``message`` is written for the model and says whether the session
    survived: an interrupted session kept its variables, a restarted one
    lost them, and the difference decides what the model should retry.
    """

    message: str


class Worker:
    """One persistent Python session in a sandboxed child process.

    Constructing a ``Worker`` spawns nothing; the first ``run()`` does.
    ``measure_sources`` are exec'd as text at every spawn — ahead of any
    model call — so a respawned worker is defined exactly the way the first
    one was. How much protection the worker gets is decided here (see
    ``protection_mode``), so a host commons cannot protect fails at
    construction, ahead of any model asking to run code.
    """

    def __init__(
        self,
        *,
        network: Network = "none",
        measure_sources: Sequence[str] = (),
        call_timeout: float = CALL_TIMEOUT,
        idle_timeout: float = IDLE_TIMEOUT,
        interrupt_grace: float = INTERRUPT_GRACE,
        spawn_timeout: float = SPAWN_TIMEOUT,
    ) -> None:
        if network not in ("none", "full"):
            raise ValueError(f"unknown network access level {network!r}")
        # There is deliberately no protection argument: the only way to
        # accept weaker protection is the environment opt-in that
        # protection_mode() consults, so a constructor keyword cannot
        # quietly trade the sandbox away.
        self._protection = protection_mode()
        self._network = network
        self._closed = False
        self._measure_sources = list(measure_sources)
        self._call_timeout = call_timeout
        self._idle_timeout = idle_timeout
        self._interrupt_grace = interrupt_grace
        self._spawn_timeout = spawn_timeout

        self._process: asyncio.subprocess.Process | None = None
        self._scratch: str | None = None
        self._synced = 0
        self._pending = 0
        self._reap_task: asyncio.Task[None] | None = None
        self._stderr_task: asyncio.Task[None] | None = None
        # Shutdowns outlive the call that started them, so they need an
        # owner that keeps them from being cancelled mid-escalation.
        self._shutdowns: set[asyncio.Task[None]] = set()
        self._last_used = 0.0
        self._lock = asyncio.Lock()
        self._ids = itertools.count(1)
        self._stderr_tail = bytearray()

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.aclose()

    async def run(
        self, code: str, handles: HandleStore | None = None
    ) -> Result | Error | Failure:
        """Run ``code`` in the session and report what came back.

        A ``Result`` is the code's answer, an ``Error`` is the code's own
        exception, and a ``Failure`` is the machinery's: the worker timed
        out, crashed, or would not start. ``handles`` is the conversation's
        result store; entries the worker has not seen yet ride along with
        the call, so a respawned worker is re-synced from the store's
        beginning.

        The pending count is incremented before the call queues on the
        lock and decremented exactly once when it settles, however it
        settles, so the reaper can never close the worker beneath a call
        in flight.
        """
        if self._closed:
            return Failure(message="the Python session is closed.")
        self._pending += 1
        try:
            async with self._lock:
                return await self._call(code, handles)
        finally:
            self._pending -= 1
            self._schedule_reap()

    async def aclose(self) -> None:
        """Close the worker, cancelling the idle reap.

        Waits for any shutdown still in flight — the reaper's included —
        so cancelling the reaper cannot strand a worker whose termination
        was mid-escalation. The lock is what a call — and with it any
        spawn in flight — holds, so once it is acquired no child can be
        created after this close returns. The close runs in its own task,
        so cancelling ``aclose()`` itself — while it waits out an in-flight
        call, say — cannot leave the worker running with the reaper
        already suppressed.
        """
        self._closed = True
        if self._reap_task is not None:
            self._reap_task.cancel()
            self._reap_task = None
        close = asyncio.ensure_future(self._close_locked())
        self._shutdowns.add(close)
        close.add_done_callback(self._shutdowns.discard)
        with contextlib.suppress(asyncio.CancelledError):
            await asyncio.shield(close)
        await asyncio.gather(*list(self._shutdowns), return_exceptions=True)

    async def _close_locked(self) -> None:
        """The close proper, serialized against any call still in flight."""
        async with self._lock:
            await self._shutdown()

    async def _call(
        self, code: str, handles: HandleStore | None
    ) -> Result | Error | Failure:
        """One call, run under the lock with the worker up."""
        try:
            await self._ensure()
            if handles is None:
                ids, new_handles = [], {}
            else:
                ids = handles.ids()
                new_handles = {id_: handles.get(id_) for id_ in ids[self._synced :]}
            call_id = f"c{next(self._ids)}"
            await self._send(
                Call(id=call_id, code=code, handles=new_handles),
                self._call_timeout,
            )
            # The write succeeded, so the worker has the handles whether or
            # not the call below settles; a respawn resets the mark to zero.
            self._synced = len(ids)
            return await self._await_reply(call_id)
        except TimeoutError:
            # The write blocked: the worker stopped reading, and a caller
            # waiting on a pipe has no timeout of its own. This one is the
            # call's.
            await self._shutdown()
            return Failure(
                message="the Python session stopped reading its calls, so it "
                "was restarted. Session variables were reset."
            )
        except asyncio.CancelledError:
            # The caller gave up mid-call, but the worker has not: it is
            # still running the code, or about to answer into a channel the
            # next call would misread as its own reply. Shut it down before
            # releasing the lock; the shutdown shields itself from a
            # repeated cancellation.
            await self._shutdown()
            raise
        except Exception as exc:  # noqa: BLE001 - any spawn or write failure fails the call
            # A spawn or write failure leaves the worker's state unknown;
            # start over rather than trust it.
            await self._shutdown()
            return Failure(message=str(exc))

    async def _send(self, message: Call, timeout: float) -> None:
        """Write ``message``, giving up on a worker that stops reading.

        A worker that never reads its stdin would otherwise hold the
        writer in ``drain()`` forever, and no call timeout would ever
        start.
        """
        assert self._writer is not None  # _ensure guarantees the channel
        await asyncio.wait_for(_protocol.write_message(self._writer, message), timeout)

    async def _await_reply(self, call_id: str) -> Result | Error | Failure:
        """Wait for the in-flight call's reply, with the timeout and escalation."""
        assert self._reader is not None
        try:
            reply = await asyncio.wait_for(
                _protocol.read_message(self._reader), self._call_timeout
            )
        except TimeoutError:
            return await self._escalate(call_id)
        except (_protocol.ProtocolError, _protocol.ChannelError) as exc:
            await self._shutdown()
            return Failure(
                message="the Python session answered with a line that does not "
                f"parse ({exc}), so it was restarted. Session variables were reset."
            )
        return await self._classify(call_id, reply)

    async def _classify(
        self, call_id: str, reply: _protocol.Message | None
    ) -> Result | Error | Failure:
        """Map a reply — or the channel's end — onto the call's outcome."""
        if reply is None:
            await self._shutdown()
            return Failure(
                message="the Python session crashed and was restarted. "
                "Session variables were reset."
            )
        if not isinstance(reply, (Result, Error)) or reply.id != call_id:
            return await self._out_of_turn()
        return reply

    async def _out_of_turn(self) -> Failure:
        """Restart a worker whose replies no longer key to the driver's calls.

        The one-in-flight contract is what keys a reply to its call; a
        reply outside it means the two sides disagree, and the worker
        cannot be trusted to stay in step.
        """
        await self._shutdown()
        return Failure(
            message="the Python session answered out of turn, so it was "
            "restarted. Session variables were reset."
        )

    async def _escalate(self, call_id: str) -> Failure:
        """Interrupt the in-flight call; kill the worker if it stays silent.

        SIGINT raises KeyboardInterrupt inside the worker's call, which
        breaks it out of the computation and leaves the session alive. A
        worker that answers within the grace window was interrupted; one
        that does not is stuck — in C code that never touches the
        interpreter, say — and is restarted instead.

        The grace-window reply is held to the same contract as any other:
        only this call's own ``Result`` or ``Error`` proves the session
        survived. Anything else means a worker whose idea of the channel
        no longer matches the driver's, and a worker like that is
        restarted rather than trusted with the next call.
        """
        process = self._process
        if process is not None and os.name == "posix":
            try:
                # The whole group, as in _terminate's kill: a call blocked
                # in subprocess.run() must take its children with it, or
                # they outlive the timeout the interrupt just enforced.
                os.killpg(process.pid, signal.SIGINT)
            except ProcessLookupError:
                # The group is gone; the worker may still be there alone.
                with contextlib.suppress(ProcessLookupError):
                    process.send_signal(signal.SIGINT)
        assert self._reader is not None
        try:
            reply = await asyncio.wait_for(
                _protocol.read_message(self._reader), self._interrupt_grace
            )
        except TimeoutError:
            await self._shutdown()
            return Failure(
                message=f"the code exceeded the {self._call_timeout:g}-second "
                "time limit and the Python session did not respond to an "
                "interrupt, so it was restarted. Session variables were reset."
            )
        except (_protocol.ProtocolError, _protocol.ChannelError):
            reply = None
        if reply is None:
            await self._shutdown()
            return Failure(
                message="the Python session crashed and was restarted. "
                "Session variables were reset."
            )
        if not isinstance(reply, (Result, Error)) or reply.id != call_id:
            return await self._out_of_turn()
        # The reply itself is discarded: whatever the call was doing when
        # the interrupt landed, the answer the model needs is that its code
        # ran out of time.
        return Failure(
            message=f"the code was interrupted after exceeding the "
            f"{self._call_timeout:g}-second time limit. The session and its "
            "variables remain available."
        )

    async def _ensure(self) -> None:
        """Spawn the worker if none is running, and define its measure sources."""
        if self._process is not None and self._process.returncode is None:
            return
        # A worker that died between calls is still attached here, scratch
        # directory included; clear it before replacing it.
        await self._shutdown()
        scratch = tempfile.mkdtemp(prefix="commons-worker-")
        # Tracked immediately, so every failure path below removes it.
        self._scratch = scratch
        spawn = asyncio.ensure_future(
            asyncio.create_subprocess_exec(
                *worker_command(str(_WORKER_SCRIPT), self._network, self._protection),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=scratch,
                env=worker_env(scratch, single_thread=needs_single_thread()),
                limit=_protocol.STREAM_LIMIT,
                # Session leader, so a kill can take the worker's whole process
                # group rather than strand anything it spawned.
                start_new_session=True,
            )
        )
        try:
            # Shielded, with the child reaped on cancellation: a process
            # created while this call is being cancelled must end up
            # tracked and killed, never leaked.
            process = await asyncio.shield(spawn)
        except asyncio.CancelledError:
            # A detached reaper finishes the spawn and kills the child, so
            # a repeated cancellation here still cannot leak it; aclose()
            # awaits it through the shutdown set.
            reap = asyncio.ensure_future(self._reap_spawn(spawn))
            self._shutdowns.add(reap)
            reap.add_done_callback(self._shutdowns.discard)
            with contextlib.suppress(asyncio.CancelledError):
                await asyncio.shield(reap)
            raise
        except Exception:
            await self._shutdown()
            raise
        self._process = process
        self._synced = 0
        self._stderr_tail = bytearray()
        self._stderr_task = asyncio.ensure_future(self._drain_stderr(process))
        reader = self._reader
        assert reader is not None  # stdout is piped
        try:
            ready = await asyncio.wait_for(
                _protocol.read_message(reader), self._spawn_timeout
            )
            if not isinstance(ready, Ready):
                # A dead or protocol-breaking worker, not a bad argument.
                raise RuntimeError(  # noqa: TRY004
                    "the worker exited before it was ready"
                )
            for index, source in enumerate(self._measure_sources):
                await self._define(index, source)
        except TimeoutError:
            await self._shutdown()
            raise RuntimeError(
                "the Python session failed to start: the worker stopped "
                "responding during startup"
            ) from None
        except Exception as exc:
            drain = self._stderr_task
            await self._shutdown()
            # Let the stderr drain finish: a worker that wrote its failure
            # just before exiting may have bytes still in the pipe. Only the
            # drain: the other shutdowns can include aclose() waiting on the
            # lock this call holds.
            if drain is not None:
                await asyncio.gather(drain, return_exceptions=True)
            detail = self._stderr_tail.decode(errors="replace").strip()
            raise RuntimeError(
                f"the Python session failed to start: {exc}"
                + (f"\n{detail}" if detail else "")
            ) from exc

    async def _define(self, index: int, source: str) -> None:
        """Define one measure source in a freshly spawned worker.

        ``_commons_define_source`` is seeded into every worker's session at
        startup: it compiles with annotations deferred and stands in for
        globals the harvest did not include, because a harvested source's
        own module imports do not exist in the session.
        """
        assert self._reader is not None
        payload = f"_commons_define_source({source!r})"
        await self._send(Call(id=f"init-{index}", code=payload), self._spawn_timeout)
        reply = await asyncio.wait_for(
            _protocol.read_message(self._reader), self._spawn_timeout
        )
        if isinstance(reply, Error):
            raise RuntimeError(  # noqa: TRY004 - a failed spawn, not a bad argument
                f"a measure source failed to define: {reply.message}"
            )
        if not isinstance(reply, Result):
            raise RuntimeError(  # noqa: TRY004 - a failed spawn, not a bad argument
                "the worker exited while defining measure sources"
            )

    async def _drain_stderr(self, process: asyncio.subprocess.Process) -> None:
        """Drain the worker's stderr, keeping the tail for spawn diagnostics.

        Draining is the point: a process whose output nobody reads blocks
        forever on a full pipe. Only startup output is ever written — the
        worker points fd 2 at a sink once it is up — so a small tail
        suffices.
        """
        if process.stderr is None:
            return
        while chunk := await process.stderr.read(4096):
            self._stderr_tail += chunk
            if len(self._stderr_tail) > _STDERR_TAIL:
                del self._stderr_tail[: len(self._stderr_tail) - _STDERR_TAIL]

    def _schedule_reap(self) -> None:
        """Close the worker after a quiet stretch; the next call respawns it.

        One timer per worker, re-armed as each call settles: the reaper
        fires only when nothing has used the worker for the whole idle
        window and no call is in flight. A closed worker gets no timer: a
        call settling as ``aclose()`` runs must not leave one ticking.
        """
        if self._closed:
            return
        self._last_used = asyncio.get_running_loop().time()
        if self._reap_task is not None:
            self._reap_task.cancel()
        self._reap_task = asyncio.ensure_future(self._reap_when_idle())

    async def _reap_when_idle(self) -> None:
        try:
            await asyncio.sleep(self._idle_timeout + 1)
        except asyncio.CancelledError:
            return
        quiet = asyncio.get_running_loop().time() - self._last_used
        if self._pending == 0 and quiet >= self._idle_timeout:
            await self._shutdown()

    async def _shutdown(self) -> None:
        """Terminate the worker, if any, and forget its state.

        The state is cleared before the termination is awaited, so a call
        that starts while the kill is still in flight spawns a fresh worker
        rather than queue behind a dying one. The scratch directory goes
        with the process: it is the worker's HOME and TMPDIR, so nothing
        in it is meant to outlive the session, and respawns would
        otherwise accumulate one directory per spawn.

        The kill and cleanup run in their own task, shielded from the
        caller: cancelling a shutdown's caller — aclose() cancelling the
        reaper mid-shutdown, say — must not strand a SIGTERM-ignoring
        worker before its SIGKILL.
        """
        process, self._process = self._process, None
        scratch, self._scratch = self._scratch, None
        self._synced = 0
        drain, self._stderr_task = self._stderr_task, None
        if drain is not None:
            # The drain ends at EOF, which the kill below forces. Track it
            # rather than cancel it, so diagnostics written just before the
            # worker died still land in the tail.
            self._shutdowns.add(drain)
            drain.add_done_callback(self._shutdowns.discard)
        if process is None and scratch is None:
            return
        finish = asyncio.ensure_future(self._finish_shutdown(process, scratch))
        self._shutdowns.add(finish)
        finish.add_done_callback(self._shutdowns.discard)
        with contextlib.suppress(asyncio.CancelledError):
            await asyncio.shield(finish)

    async def _reap_spawn(
        self, spawn: asyncio.Task[asyncio.subprocess.Process]
    ) -> None:
        """Kill a child whose spawning call was cancelled mid-spawn.

        Runs detached and touches none of the worker's shared state: the
        next call may already have spawned a replacement.
        """
        try:
            process = await spawn
        except Exception:  # noqa: BLE001 - a failed spawn has no child to kill
            return
        await _terminate(process, TERMINATE_GRACE)

    async def _finish_shutdown(
        self, process: asyncio.subprocess.Process | None, scratch: str | None
    ) -> None:
        """The shutdown's slow half: the bounded kill, then the cleanup."""
        if process is not None:
            if process.returncode is not None and os.name == "posix":
                # The leader is dead, so _terminate below will not signal
                # anything — but its process group may not be dead: a
                # background child outlives the crash that took the worker.
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
            await _terminate(process, TERMINATE_GRACE)
        if scratch is not None:
            # The process is gone, so its files can be removed; model code
            # may have left some unreadable, which is not a reason to fail.
            shutil.rmtree(scratch, ignore_errors=True)

    @property
    def _reader(self) -> asyncio.StreamReader | None:
        return self._process.stdout if self._process is not None else None

    @property
    def _writer(self) -> asyncio.StreamWriter | None:
        return self._process.stdin if self._process is not None else None

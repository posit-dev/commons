"""The worker's lifecycle: lazy spawn, one call at a time, timeouts, and the idle reap.

A ``Worker`` owns one persistent Python session, started through an
``ExecBackend``. No process exists until the first call; one that sits idle
is closed, and the next call starts a fresh one. Calls are serialized
through an ``asyncio.Lock``, because the single session can only run one
piece of code at a time. A call that outruns its time limit is interrupted
first and restarted only if the interrupt goes unanswered, because the two
outcomes mean different things: an interrupted session keeps its variables,
a restarted one has lost them.

``run_r_tool()`` and ``worker_await()`` in pkg-r/R/run-r.R implement the
same lifecycle over callr's promise chain.
"""

from __future__ import annotations

import asyncio
import itertools
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Self

from .._handles import HandleStore
from . import _protocol
from ._backend import ExecBackend, LocalBackend, Network, WorkerSession
from ._protocol import Call, Error, Ready, Result

__all__ = ["Failure", "Worker"]

CALL_TIMEOUT = 60.0
IDLE_TIMEOUT = 600.0

# How long an interrupted worker gets to answer before it is restarted. The
# interrupt raises KeyboardInterrupt in the worker's call, so a responsive
# one answers almost immediately.
INTERRUPT_GRACE = 5.0

# Startup is interpreter boot plus the sandbox engage, neither of which
# should take seconds; the bound exists so a wedged start fails the call
# rather than hanging it.
SPAWN_TIMEOUT = 30.0


@dataclass(frozen=True, kw_only=True)
class Failure:
    """A call that never got an answer from the worker.

    ``message`` is written for the model and says whether the session
    survived: an interrupted session kept its variables, a restarted one
    lost them, and the difference decides what the model should retry.
    """

    message: str


class Worker:
    """One persistent Python session in a sandboxed worker.

    Constructing a ``Worker`` starts nothing; the first ``run()`` does.
    ``measure_sources`` are exec'd as text at every start, ahead of any
    model call, so a restarted worker is defined exactly the way the first
    one was. ``backend`` decides where the worker runs; the default
    ``LocalBackend`` decides its protection at construction, so a host
    commons cannot protect fails here, ahead of any model asking to run code.
    """

    def __init__(
        self,
        *,
        network: Network = "none",
        measure_sources: Sequence[str] = (),
        backend: ExecBackend | None = None,
        call_timeout: float = CALL_TIMEOUT,
        idle_timeout: float = IDLE_TIMEOUT,
        interrupt_grace: float = INTERRUPT_GRACE,
        spawn_timeout: float = SPAWN_TIMEOUT,
    ) -> None:
        if network not in ("none", "full"):
            raise ValueError(f"unknown network access level {network!r}")
        self._backend = backend if backend is not None else LocalBackend()
        self._network: Network = network
        self._closed = False
        self._measure_sources = list(measure_sources)
        self._call_timeout = call_timeout
        self._idle_timeout = idle_timeout
        self._interrupt_grace = interrupt_grace
        self._spawn_timeout = spawn_timeout

        self._session: WorkerSession | None = None
        # How many of the store's handles the running worker has, and which
        # store they came from; a different store is synced from its start.
        self._synced = 0
        self._synced_store: HandleStore | None = None
        self._pending = 0
        self._reap_task: asyncio.Task[None] | None = None
        # A close outlives a cancelled aclose(), so it needs an owner that
        # keeps it from being garbage-collected.
        self._closing: asyncio.Task[None] | None = None
        self._last_used = 0.0
        self._lock = asyncio.Lock()
        self._ids = itertools.count(1)

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
        result store; entries the worker has not seen yet are sent ahead
        of the call, so a restarted worker is re-synced from the store's
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
                # A call queued behind aclose() must not start a worker that
                # the close would then have to kill.
                if self._closed:
                    return Failure(message="the Python session is closed.")
                return await self._call(code, handles)
        finally:
            self._pending -= 1
            self._schedule_reap()

    async def aclose(self) -> None:
        """Close the worker, cancelling the idle reap.

        The close takes the lock, which a call, and with it any start in
        flight, holds; once it is acquired no worker can be started after
        this close returns. The close runs in its own task, so cancelling
        ``aclose()`` while it waits out an in-flight call still closes the
        worker, and the cancellation still reaches the caller. The
        backend's shutdowns, the reaper's included, are waited for last.
        """
        self._closed = True
        if self._reap_task is not None:
            self._reap_task.cancel()
            self._reap_task = None
        if self._closing is None:
            self._closing = asyncio.ensure_future(self._close_locked())
        await asyncio.shield(self._closing)

    async def _close_locked(self) -> None:
        """The close proper, serialized against any call still in flight."""
        async with self._lock:
            await self._shutdown()
        await self._backend.aclose()

    async def _call(
        self, code: str, handles: HandleStore | None
    ) -> Result | Error | Failure:
        """One call, run under the lock with the worker up."""
        try:
            session = await self._ensure()
            if handles is not None:
                failure = await self._sync(session, handles)
                if failure is not None:
                    return failure
            call_id = f"c{next(self._ids)}"
            await self._send(session, Call(id=call_id, code=code))
            return await self._await_reply(session, call_id)
        except TimeoutError:
            # The write blocked: the worker stopped reading, and a caller
            # waiting on a pipe has no timeout of its own. This one is the
            # call's.
            await self._shutdown()
            return Failure(
                message="the Python session stopped reading its calls, so it "
                "was restarted. Session variables were reset."
            )
        except ConnectionError:
            # The worker exited between calls without its exit being seen
            # yet, so the write found no reader.
            await self._shutdown()
            return Failure(
                message="the Python session exited and was restarted. "
                "Session variables were reset."
            )
        except asyncio.CancelledError:
            # The caller gave up mid-call, but the worker has not: it is
            # still running the code, or about to answer into a channel the
            # next call would misread as its own reply. Shut it down before
            # releasing the lock.
            await self._shutdown()
            raise
        except Exception as exc:  # noqa: BLE001 - any start or write failure fails the call
            # A start or write failure leaves the worker's state unknown;
            # start over rather than trust it.
            await self._shutdown()
            return Failure(message=str(exc))

    async def _sync(
        self, session: WorkerSession, handles: HandleStore
    ) -> Failure | None:
        """Send the store's handles the worker does not have, one message each.

        A restarted worker is sent the whole store again, and in a single
        message a large store would outgrow the channel and be shrunk to
        reprs. Each handle counts as synced once the worker acknowledges
        it; one the worker could not decode is skipped rather than retried
        on every call.
        """
        if handles is not self._synced_store:
            self._synced_store, self._synced = handles, 0
        for id_ in handles.ids()[self._synced :]:
            sync_id = f"s{next(self._ids)}"
            await self._send(
                session,
                Call(id=sync_id, code="None", handles={id_: handles.get(id_)}),
            )
            try:
                reply = await asyncio.wait_for(
                    _protocol.read_message(session.stdout), self._call_timeout
                )
            except (_protocol.ProtocolError, _protocol.ChannelError) as exc:
                await self._shutdown()
                return _unparseable(exc)
            outcome = await self._classify(sync_id, reply)
            if isinstance(outcome, Failure):
                return outcome
            self._synced += 1
        return None

    async def _send(self, session: WorkerSession, message: Call) -> None:
        """Write ``message``, giving up on a worker that stops reading.

        A worker that never reads its stdin would otherwise block the
        writer in ``drain()`` forever, and no call timeout would ever
        start.
        """
        await asyncio.wait_for(
            _protocol.write_message(session.stdin, message), self._call_timeout
        )

    async def _await_reply(
        self, session: WorkerSession, call_id: str
    ) -> Result | Error | Failure:
        """Wait for the in-flight call's reply, with the timeout and escalation."""
        try:
            reply = await asyncio.wait_for(
                _protocol.read_message(session.stdout), self._call_timeout
            )
        except TimeoutError:
            return await self._escalate(session, call_id)
        except (_protocol.ProtocolError, _protocol.ChannelError) as exc:
            await self._shutdown()
            return _unparseable(exc)
        return await self._classify(call_id, reply)

    async def _classify(
        self, call_id: str, reply: _protocol.Message | None
    ) -> Result | Error | Failure:
        """Map a reply, or the channel's end, onto the call's outcome."""
        if reply is None:
            await self._shutdown()
            return Failure(
                message="the Python session crashed and was restarted. "
                "Session variables were reset."
            )
        if not isinstance(reply, (Result, Error)) or reply.id != call_id:
            # The one-in-flight contract is what keys a reply to its call; a
            # reply outside it means the two sides disagree, and the worker
            # cannot be trusted to stay in step.
            await self._shutdown()
            return Failure(
                message="the Python session answered out of turn, so it was "
                "restarted. Session variables were reset."
            )
        return reply

    async def _escalate(self, session: WorkerSession, call_id: str) -> Failure:
        """Interrupt the in-flight call; restart the worker if it stays silent.

        The interrupt raises KeyboardInterrupt inside the worker's call,
        which breaks it out of the computation and leaves the session alive.
        A worker that answers within the grace window was interrupted; one
        that does not is stuck, in C code that never checks for signals,
        say, and is restarted instead.

        The grace-window reply must meet the same contract as any other:
        only this call's own ``Result`` or ``Error`` proves the session
        survived.
        """
        session.interrupt()
        try:
            reply = await asyncio.wait_for(
                _protocol.read_message(session.stdout), self._interrupt_grace
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
        outcome = await self._classify(call_id, reply)
        if isinstance(outcome, Failure):
            return outcome
        # The reply itself is discarded: whatever the call was doing when
        # it was interrupted, the answer the model needs is that its code
        # ran out of time.
        return Failure(
            message=f"the code was interrupted after exceeding the "
            f"{self._call_timeout:g}-second time limit. The session and its "
            "variables remain available."
        )

    async def _ensure(self) -> WorkerSession:
        """Start the worker if none is running, and define its measure sources."""
        if self._session is not None and self._session.returncode is None:
            return self._session
        # A worker that died between calls is still attached here; close it
        # before replacing it, so its files go with it.
        await self._shutdown()
        session = await self._backend.start(network=self._network)
        self._session = session
        self._synced = 0
        try:
            ready = await asyncio.wait_for(
                _protocol.read_message(session.stdout), self._spawn_timeout
            )
            if not isinstance(ready, Ready):
                # A dead or protocol-breaking worker, not a bad argument.
                raise RuntimeError(  # noqa: TRY004
                    "the worker exited before it was ready"
                )
            for index, source in enumerate(self._measure_sources):
                await self._define(session, index, source)
        except TimeoutError:
            await self._shutdown()
            raise RuntimeError(
                "the Python session failed to start: the worker stopped "
                "responding during startup"
            ) from None
        except Exception as exc:
            await self._shutdown()
            # A worker that wrote its failure just before exiting may have
            # bytes still in the pipe; the session's stderr waits for them.
            detail = await session.stderr()
            raise RuntimeError(
                f"the Python session failed to start: {exc}"
                + (f"\n{detail}" if detail else "")
            ) from exc
        return session

    async def _define(self, session: WorkerSession, index: int, source: str) -> None:
        """Define one measure source in a freshly started worker.

        ``_commons_define_source`` is seeded into every worker's session at
        startup: it compiles with annotations deferred and stands in for
        globals the harvest did not include, because a harvested source's
        own module imports do not exist in the session.
        """
        payload = f"_commons_define_source({source!r})"
        await asyncio.wait_for(
            _protocol.write_message(
                session.stdin, Call(id=f"init-{index}", code=payload)
            ),
            self._spawn_timeout,
        )
        reply = await asyncio.wait_for(
            _protocol.read_message(session.stdout), self._spawn_timeout
        )
        if isinstance(reply, Error):
            raise RuntimeError(  # noqa: TRY004 - a failed start, not a bad argument
                f"a measure source failed to define: {reply.message}"
            )
        if not isinstance(reply, Result):
            raise RuntimeError(  # noqa: TRY004 - a failed start, not a bad argument
                "the worker exited while defining measure sources"
            )

    def _schedule_reap(self) -> None:
        """Close the worker after a quiet stretch; the next call restarts it.

        One timer per worker, re-armed as each call settles: the reaper
        fires only when nothing has used the worker for the whole idle
        window and no call is in flight. A closed worker gets no timer: a
        call settling as ``aclose()`` runs must not leave one running.
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
        """Close the worker, if any, and forget its state.

        The state is cleared before the close is awaited, so a call that
        starts while the kill is still in flight starts a fresh worker
        rather than queue behind a dying one. The backend finishes the
        close even if this caller is cancelled while it waits.
        """
        session, self._session = self._session, None
        self._synced = 0
        if session is not None:
            await session.close()


def _unparseable(exc: Exception) -> Failure:
    return Failure(
        message="the Python session answered with a line that does not "
        f"parse ({exc}), so it was restarted. Session variables were reset."
    )

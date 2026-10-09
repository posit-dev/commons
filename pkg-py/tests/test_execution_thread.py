"""The worker thread: one session, reachable from sync callers and any event loop."""

from __future__ import annotations

import asyncio
import threading

import pytest

from commons._execution._driver import Failure, Worker
from commons._execution._protocol import Result
from commons._execution._thread import WorkerThread


@pytest.fixture
def runner():
    worker_thread = WorkerThread(Worker(call_timeout=10))
    yield worker_thread
    worker_thread.close()


def test_sync_and_async_callers_share_one_session(runner: WorkerThread) -> None:
    assert isinstance(runner.run_sync("x = 41"), Result)

    async def from_a_loop() -> Result:
        reply = await runner.run("x + 1")
        assert isinstance(reply, Result)
        return reply

    assert asyncio.run(from_a_loop()).value == 42


def test_the_session_runs_off_the_callers_loop(runner: WorkerThread) -> None:
    async def caller() -> tuple[int, bool]:
        ticks = 0
        stop = asyncio.Event()

        async def tick() -> None:
            nonlocal ticks
            while not stop.is_set():
                ticks += 1
                await asyncio.sleep(0.01)

        ticker = asyncio.ensure_future(tick())
        reply = await runner.run("import time; time.sleep(0.5)")
        stop.set()
        await ticker
        return ticks, isinstance(reply, Result)

    ticks, ok = asyncio.run(caller())
    assert ok
    # The caller's loop kept running while the call slept.
    assert ticks > 10


def test_no_thread_starts_before_the_first_call() -> None:
    before = threading.active_count()
    worker_thread = WorkerThread(Worker())
    assert threading.active_count() == before
    worker_thread.close()


def test_a_cancelled_caller_cancels_the_call(runner: WorkerThread) -> None:
    async def cancel_midway() -> None:
        call = asyncio.ensure_future(runner.run("import time; time.sleep(30)"))
        await asyncio.sleep(1)
        call.cancel()
        with pytest.raises(asyncio.CancelledError):
            await call

    asyncio.run(cancel_midway())
    # The cancelled call's worker was shut down; the next one respawns.
    reply = runner.run_sync("1 + 1")
    assert isinstance(reply, Result)
    assert reply.value == 2


def test_close_ends_the_thread_and_later_calls_fail(runner: WorkerThread) -> None:
    runner.run_sync("1")
    runner.close()
    runner.close()
    reply = runner.run_sync("1")
    assert isinstance(reply, Failure)
    assert "closed" in reply.message

"""The worker thread: one session, reachable from sync callers and any event loop."""

from __future__ import annotations

import asyncio
import threading
import time

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


def test_close_cancels_a_running_call_rather_than_waiting_it_out() -> None:
    worker_thread = WorkerThread(Worker(call_timeout=60))
    worker_thread.run_sync("1")
    replies: list[object] = []
    caller = threading.Thread(
        target=lambda: replies.append(
            worker_thread.run_sync("import time; time.sleep(60)")
        )
    )
    caller.start()
    time.sleep(1)
    started = time.monotonic()
    worker_thread.close()
    caller.join(10)
    assert time.monotonic() - started < 15
    assert replies == [Failure(message="the Python session is closed.")]


def test_an_async_call_running_when_the_thread_closes_is_told_it_closed() -> None:
    worker_thread = WorkerThread(Worker(call_timeout=60))

    async def caller() -> object:
        await worker_thread.run("1")
        call = asyncio.ensure_future(worker_thread.run("import time; time.sleep(60)"))
        await asyncio.sleep(1)
        # close() blocks, so it runs off this loop, which keeps serving the call.
        await asyncio.to_thread(worker_thread.close)
        return await asyncio.wait_for(call, 10)

    assert asyncio.run(caller()) == Failure(message="the Python session is closed.")

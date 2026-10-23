"""The worker thread: one session, reachable from sync callers and any event loop."""

from __future__ import annotations

import asyncio
import signal
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
    worker_thread = WorkerThread(Worker())
    assert worker_thread._thread is None
    worker_thread.close()
    assert worker_thread._thread is None


def test_run_sync_refuses_the_workers_own_thread(runner: WorkerThread) -> None:
    runner.run_sync("1")
    assert runner._loop is not None

    async def from_the_loop() -> None:
        runner.run_sync("1")

    future = asyncio.run_coroutine_threadsafe(from_the_loop(), runner._loop)
    with pytest.raises(RuntimeError, match="deadlock"):
        future.result(10)


def test_ctrl_c_while_waiting_stops_the_call() -> None:
    worker_thread = WorkerThread(Worker(call_timeout=60))
    main = threading.main_thread().ident
    assert main is not None
    interrupt = threading.Timer(1, signal.pthread_kill, (main, signal.SIGINT))
    try:
        worker_thread.run_sync("x = 1")
        interrupt.start()
        with pytest.raises(KeyboardInterrupt):
            worker_thread.run_sync("import time; time.sleep(60)")
        started = time.monotonic()
        # Without the cancel, this call would queue behind the sleep.
        reply = worker_thread.run_sync("x + 1")
        assert time.monotonic() - started < 15
        assert isinstance(reply, Result)
        # The interrupt stopped the sleep and kept the session.
        assert reply.value == 2
        assert not worker_thread.take_restart()
    finally:
        # A call that returned early must not leave the signal for a later test.
        interrupt.cancel()
        worker_thread.close()


def test_close_from_the_loops_own_thread_returns_and_the_thread_stops() -> None:
    worker_thread = WorkerThread(Worker())
    worker_thread.run_sync("1")
    loop, thread = worker_thread._loop, worker_thread._thread
    assert loop is not None and thread is not None
    loop.call_soon_threadsafe(worker_thread.close)
    thread.join(15)
    assert not thread.is_alive()
    assert loop.is_closed()


def test_a_cancelled_caller_cancels_the_call() -> None:
    worker_thread = WorkerThread(Worker(call_timeout=60))

    async def cancel_midway() -> None:
        await worker_thread.run("x = 1")
        call = asyncio.ensure_future(worker_thread.run("import time; time.sleep(60)"))
        await asyncio.sleep(1)
        call.cancel()
        with pytest.raises(asyncio.CancelledError):
            await call

    try:
        asyncio.run(cancel_midway())
        started = time.monotonic()
        # The cancelled call was interrupted, so the next one runs rather
        # than queue behind the sleep, in the same session.
        reply = worker_thread.run_sync("x + 1")
        assert time.monotonic() - started < 15
        assert isinstance(reply, Result)
        assert reply.value == 2
        assert not worker_thread.take_restart()
    finally:
        worker_thread.close()


def test_close_ends_the_thread_and_later_calls_fail(runner: WorkerThread) -> None:
    runner.run_sync("1")
    runner.close()
    runner.close()
    reply = runner.run_sync("1")
    assert isinstance(reply, Failure)
    assert "closed" in reply.message


def test_close_cancels_a_running_call_rather_than_waiting_it_out() -> None:
    worker_thread = WorkerThread(Worker(call_timeout=60))
    try:
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
    finally:
        worker_thread.close()


def test_an_async_call_running_when_the_thread_closes_is_told_it_closed() -> None:
    worker_thread = WorkerThread(Worker(call_timeout=60))

    async def caller() -> object:
        await worker_thread.run("1")
        call = asyncio.ensure_future(worker_thread.run("import time; time.sleep(60)"))
        await asyncio.sleep(1)
        # close() blocks, so it runs off this loop, which keeps serving the call.
        await asyncio.to_thread(worker_thread.close)
        return await asyncio.wait_for(call, 10)

    try:
        assert asyncio.run(caller()) == Failure(
            message="the Python session is closed."
        )
    finally:
        worker_thread.close()


class FailingClose(Worker):
    async def aclose(self) -> None:
        await super().aclose()
        raise OSError("shutdown failed")


def test_a_shutdown_that_raises_still_stops_the_thread_and_closes_the_loop() -> None:
    worker_thread = WorkerThread(FailingClose())
    worker_thread.run_sync("1")
    loop, thread = worker_thread._loop, worker_thread._thread
    assert loop is not None and thread is not None
    with pytest.raises(OSError, match="shutdown failed"):
        worker_thread.close()
    assert not thread.is_alive()
    assert loop.is_closed()


def test_a_call_cancelled_while_it_waits_leaves_the_session_alone() -> None:
    worker_thread = WorkerThread(Worker(call_timeout=60))

    async def cancel_the_queued_one() -> object:
        await worker_thread.run("x = 41")
        running = asyncio.ensure_future(
            worker_thread.run("import time; time.sleep(2)\nx + 1")
        )
        await asyncio.sleep(0.5)
        queued = asyncio.ensure_future(worker_thread.run("1"))
        await asyncio.sleep(0.5)
        queued.cancel()
        with pytest.raises(asyncio.CancelledError):
            await queued
        return await running

    try:
        reply = asyncio.run(cancel_the_queued_one())
        assert isinstance(reply, Result)
        assert reply.value == 42
        assert not worker_thread.take_restart()
    finally:
        worker_thread.close()


def test_a_stopped_call_says_so_and_the_session_survives() -> None:
    worker_thread = WorkerThread(Worker(call_timeout=60))
    try:
        worker_thread.run_sync("x = 41")
        replies: list[object] = []
        caller = threading.Thread(
            target=lambda: replies.append(
                worker_thread.run_sync("import time; time.sleep(60)")
            )
        )
        caller.start()
        time.sleep(1)
        started = time.monotonic()
        worker_thread.stop_calls()
        caller.join(15)
        assert time.monotonic() - started < 15
        assert replies == [Failure(message="the user stopped this call before it finished.")]
        # The interrupt stopped the sleep, so x is still defined.
        reply = worker_thread.run_sync("x")
        assert isinstance(reply, Result)
        assert reply.value == 41
        assert not worker_thread.take_restart()
    finally:
        worker_thread.close()

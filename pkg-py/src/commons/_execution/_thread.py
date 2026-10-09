"""A worker on an event loop of its own, so any caller can reach one session.

chatlas runs an async tool only from ``stream_async()``, and a sync tool
directly on the caller's event loop, where a long call would stall every
other task on it. Keeping the ``Worker`` on a private loop in a background
thread lets an async caller await a call without blocking its loop, and a
sync caller block on the same session, so variables persist whichever way
the agent is asked.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import contextlib
import threading

from .._handles import HandleStore
from ._driver import Failure, Worker
from ._protocol import Error, Result

__all__ = ["WorkerThread"]

# How long close() waits for the worker's shutdown, which is itself bounded
# by its grace periods once the calls in flight are cancelled.
CLOSE_TIMEOUT = 30.0

_CLOSED = Failure(message="the Python session is closed.")

_Reply = Result | Error | Failure


class WorkerThread:
    """Runs ``worker`` on a loop in a daemon thread, started by the first call."""

    def __init__(self, worker: Worker) -> None:
        self._worker = worker
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        # Guards the lifecycle: a call is either submitted before close()
        # begins, and so cancelled by it, or refused as closed.
        self._lock = threading.Lock()
        self._closed = False
        self._calls: set[concurrent.futures.Future[_Reply]] = set()

    async def run(self, code: str, handles: HandleStore | None = None) -> _Reply:
        """Run ``code`` without blocking the caller's event loop.

        Cancelling the caller cancels the call, which shuts the worker down
        the way a cancelled ``Worker.run`` does.
        """
        future = self._submit(code, handles)
        if future is None:
            return _CLOSED
        try:
            return await asyncio.wrap_future(future)
        except asyncio.CancelledError:
            task = asyncio.current_task()
            if self._closed and future.cancelled() and not (task and task.cancelling()):
                return _CLOSED
            raise

    def run_sync(self, code: str, handles: HandleStore | None = None) -> _Reply:
        """Run ``code``, blocking the calling thread until the reply arrives."""
        if threading.current_thread() is self._thread:
            raise RuntimeError("run_sync() would deadlock on the worker's own loop")
        future = self._submit(code, handles)
        if future is None:
            return _CLOSED
        try:
            return future.result()
        except concurrent.futures.CancelledError:
            if self._closed:
                return _CLOSED
            raise

    def close(self) -> None:
        """Close the worker, then stop the loop and its thread. Safe to repeat.

        Calls in flight are cancelled first, so the worker shuts down within
        its grace periods rather than after a call's timeout. A shutdown that
        still overruns ``CLOSE_TIMEOUT`` finishes in the background, and the
        loop stops only once it has.
        """
        with self._lock:
            if self._closed:
                return
            self._closed = True
            loop, thread = self._loop, self._thread
            calls = list(self._calls)
        if loop is None or thread is None:
            return
        for call in calls:
            call.cancel()
        closing = asyncio.run_coroutine_threadsafe(self._worker.aclose(), loop)
        closing.add_done_callback(lambda _: loop.call_soon_threadsafe(loop.stop))
        with contextlib.suppress(TimeoutError):
            closing.result(CLOSE_TIMEOUT)
        thread.join(CLOSE_TIMEOUT)
        if not thread.is_alive():
            loop.close()

    def _submit(
        self, code: str, handles: HandleStore | None
    ) -> concurrent.futures.Future[_Reply] | None:
        with self._lock:
            if self._closed:
                return None
            loop = self._ensure_loop()
            # The store is read from the worker's thread while the caller
            # waits. A store only grows, and each read is one dict operation.
            future = asyncio.run_coroutine_threadsafe(
                self._worker.run(code, handles), loop
            )
            self._calls.add(future)
        future.add_done_callback(self._forget)
        return future

    def _forget(self, future: concurrent.futures.Future[_Reply]) -> None:
        with self._lock:
            self._calls.discard(future)

    def _ensure_loop(self) -> asyncio.AbstractEventLoop:
        """The loop, started on first use. Called with the lock held."""
        if self._loop is None:
            loop = asyncio.new_event_loop()
            thread = threading.Thread(
                target=loop.run_forever, name="commons-python-session", daemon=True
            )
            thread.start()
            self._loop, self._thread = loop, thread
        return self._loop

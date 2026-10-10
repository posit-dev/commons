"""Runs the session's ``Worker`` in a background thread with its own event loop.

chatlas runs an async tool only from ``stream_async()``, and runs a sync tool
on the caller's event loop, where a long call would stop every other task on
that loop. With the ``Worker`` in its own thread, an async caller can wait for
a call without blocking its loop, and a sync caller can block on the same
session. Variables therefore persist whether the agent is used through
``chat()`` or ``stream_async()``.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
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
    """Runs ``worker`` in a background thread, which starts on the first call."""

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

        If the caller is cancelled, the call is cancelled too, and the worker
        shuts down as it does when ``Worker.run`` is cancelled.
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
        except BaseException:
            # Ctrl-C while waiting stops the call, as cancelling an async
            # caller does, rather than leaving it to run out its timeout.
            future.cancel()
            raise

    def close(self) -> None:
        """Close the worker, then stop the loop and its thread.

        Calling it again does nothing. Running calls are cancelled first, so
        the worker stops quickly instead of waiting for a call to time out. If
        the shutdown takes longer than ``CLOSE_TIMEOUT``, it continues in the
        background, and the loop stops when it ends. When called from the
        loop's own thread, it starts the shutdown and returns at once.
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
        # Waiting here on the loop's own thread would block the shutdown.
        if threading.current_thread() is thread:
            return
        try:
            closing.result(CLOSE_TIMEOUT)
        except TimeoutError:
            return
        finally:
            if closing.done():
                thread.join(CLOSE_TIMEOUT)

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
        """Return the loop, starting it and its thread if needed. Needs the lock."""
        if self._loop is None:
            loop = asyncio.new_event_loop()
            thread = threading.Thread(
                target=_run_loop,
                args=(loop,),
                name="commons-python-session",
                daemon=True,
            )
            thread.start()
            self._loop, self._thread = loop, thread
        return self._loop


def _run_loop(loop: asyncio.AbstractEventLoop) -> None:
    """Run ``loop`` until it is stopped, then close it, however close() was called."""
    try:
        loop.run_forever()
    finally:
        loop.close()

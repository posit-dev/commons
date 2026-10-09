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
# by its grace periods; the margin covers a loop slow to get to it.
CLOSE_TIMEOUT = 30.0

_CLOSED = Failure(message="the Python session is closed.")


class WorkerThread:
    """Runs ``worker`` on a loop in a daemon thread, started by the first call."""

    def __init__(self, worker: Worker) -> None:
        self._worker = worker
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._start_lock = threading.Lock()
        self._closed = False

    async def run(
        self, code: str, handles: HandleStore | None = None
    ) -> Result | Error | Failure:
        """Run ``code`` without blocking the caller's event loop.

        Cancelling the caller cancels the call, which shuts the worker down
        the way a cancelled ``Worker.run`` does.
        """
        future = self._submit(code, handles)
        if future is None:
            return _CLOSED
        return await asyncio.wrap_future(future)

    def run_sync(
        self, code: str, handles: HandleStore | None = None
    ) -> Result | Error | Failure:
        """Run ``code``, blocking the calling thread until the reply arrives."""
        if threading.current_thread() is self._thread:
            raise RuntimeError("run_sync() would deadlock on the worker's own loop")
        future = self._submit(code, handles)
        if future is None:
            return _CLOSED
        return future.result()

    def close(self) -> None:
        """Close the worker, then stop the loop and its thread. Safe to repeat."""
        with self._start_lock:
            if self._closed:
                return
            self._closed = True
            loop, thread = self._loop, self._thread
        if loop is None or thread is None:
            return
        closing = asyncio.run_coroutine_threadsafe(self._worker.aclose(), loop)
        with contextlib.suppress(concurrent.futures.TimeoutError, RuntimeError):
            closing.result(CLOSE_TIMEOUT)
        loop.call_soon_threadsafe(loop.stop)
        thread.join(CLOSE_TIMEOUT)
        if not thread.is_alive():
            loop.close()

    def _submit(
        self, code: str, handles: HandleStore | None
    ) -> concurrent.futures.Future[Result | Error | Failure] | None:
        loop = self._ensure_loop()
        if loop is None:
            return None
        # The store is read from the worker's thread while the caller waits.
        # A store only ever grows, and each read is a single dict operation.
        return asyncio.run_coroutine_threadsafe(self._worker.run(code, handles), loop)

    def _ensure_loop(self) -> asyncio.AbstractEventLoop | None:
        with self._start_lock:
            if self._closed:
                return None
            if self._loop is None:
                loop = asyncio.new_event_loop()
                thread = threading.Thread(
                    target=loop.run_forever, name="commons-python-session", daemon=True
                )
                thread.start()
                self._loop, self._thread = loop, thread
            return self._loop

"""A shiny session a test can drive, for the parts of the UI that need one."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from shiny.express._stub_session import ExpressStubSession


class IdleSession(ExpressStubSession):
    """A shiny session that keeps the idle callbacks so a test can run them.

    The stub session shiny uses to render express UI discards what
    `on_flushed()` registers, because nothing ever flushes it.
    """

    def __init__(self) -> None:
        super().__init__()
        self.idle_callbacks: list[tuple[Callable[[], Any], bool]] = []

    def on_flushed(
        self, fn: Callable[[], Any], once: bool = True
    ) -> Callable[[], None]:
        self.idle_callbacks.append((fn, once))
        return lambda: None

    def go_idle(self) -> None:
        # A `once` callback deregisters when it fires; the rest run each flush.
        callbacks, self.idle_callbacks = self.idle_callbacks, []
        for fn, once in callbacks:
            fn()
            if not once:
                self.idle_callbacks.append((fn, once))

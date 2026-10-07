"""Best-effort guardrails for a worker that runs without a sandbox.

Guardrails mode exists so a host commons cannot sandbox can still run, and
it provides no security boundary: model code that looks for a way around
these checks will find one. They stop ordinary code from reading outside
the worker's roots, writing outside its scratch directory, starting
processes, or reaching the network under ``network="none"``.

The checks are an audit hook (``sys.addaudithook``), consulted only while
model code runs, so the worker's own reads and writes are left alone. A
denied operation raises ``PermissionError``, which libraries that probe
the filesystem already tolerate. pkg-r/inst/worker/worker.R applies the
same policy to R by replacing its file, process, and connection functions
for the length of a call.

Imported by bare name from the worker; nothing here may import ``commons``.
"""

from __future__ import annotations

import os
import sys
import threading
from collections.abc import Callable, Iterable
from typing import Any

__all__ = ["Guardrails", "engage"]

# Audit events naming a path, mapped to the access each argument needs.
# https://docs.python.org/3/library/audit_events.html lists them all.
# "entry" is a write to the directory that lists the path, for operations
# that act on a symlink itself rather than on its target. A hard link is a
# second name for its source, through which the source can be written.
_PATH_EVENTS: dict[str, tuple[str, ...]] = {
    "os.listdir": ("read",),
    "os.scandir": ("read",),
    "os.chdir": ("read",),
    "os.listxattr": ("read",),
    "os.getxattr": ("read",),
    "os.mkdir": ("entry",),
    "os.remove": ("entry",),
    "os.rmdir": ("entry",),
    "os.rename": ("entry", "entry"),
    "os.link": ("write", "entry"),
    "os.symlink": ("read", "entry"),
    "os.truncate": ("write",),
    "os.chmod": ("write",),
    "os.chown": ("write",),
    "os.chflags": ("write",),
    "os.lchflags": ("entry",),
    "os.utime": ("write",),
    "os.setxattr": ("write",),
    "os.removexattr": ("write",),
    "shutil.copyfile": ("read", "write"),
    "shutil.copymode": ("read", "write"),
    "shutil.copystat": ("read", "write"),
    "shutil.copytree": ("read", "write"),
    "shutil.move": ("entry", "entry"),
    "shutil.rmtree": ("entry",),
    "shutil.chown": ("write",),
    "sqlite3.connect": ("write",),
}

_PROCESS_EVENTS = frozenset(
    {
        "subprocess.Popen",
        "os.system",
        "os.exec",
        "os.spawn",
        "os.posix_spawn",
        "os.fork",
        "os.forkpty",
        "os.startfile",
        "pty.spawn",
        "webbrowser.open",
    }
)

_NETWORK_EVENTS = frozenset(
    {
        "socket.connect",
        "socket.bind",
        "socket.sendto",
        "socket.sendmsg",
        "socket.getaddrinfo",
        "socket.gethostbyname",
        "socket.gethostbyaddr",
        "socket.getnameinfo",
        "http.client.connect",
        "ftplib.connect",
        "smtplib.connect",
        "imaplib.open",
        "poplib.connect",
        "nntplib.connect",
        "telnetlib.Telnet.open",
    }
)

# Flags that make an open a write, for an ``open`` event that reports them.
_WRITE_FLAGS = os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_TRUNC


def _canonical(path: str) -> str:
    """``path`` made absolute with every symlink in its existing part resolved.

    A path that does not exist yet resolves through its nearest existing
    ancestor, so a link to the outside cannot be written through by naming
    a file beneath it that has yet to be created.
    """
    return os.path.realpath(os.path.join(os.getcwd(), path))


def _entry(path: str) -> str:
    """``path`` with its directory canonicalized and its final name kept.

    This names the directory entry itself, so a symlink is not followed.
    """
    head, tail = os.path.split(os.path.join(os.getcwd(), path).rstrip("/"))
    if tail in ("", ".", ".."):
        return _canonical(path)
    return os.path.join(_canonical(head), tail)


def _within(path: str, roots: Iterable[str]) -> bool:
    return any(path == root or path.startswith(root.rstrip("/") + "/") for root in roots)


class Guardrails:
    """The audit hook's policy, separated from the hook so it can be tested."""

    def __init__(
        self,
        read_roots: Iterable[str],
        write_roots: Iterable[str],
        *,
        network: str,
        active: Callable[[], bool],
    ) -> None:
        canonical = lambda roots: [os.path.realpath(r) for r in roots]
        self.write_roots = canonical(write_roots) + [os.devnull]
        self.read_roots = canonical(read_roots) + self.write_roots
        self.network = network
        self.active = active
        self._checking = threading.local()

    def __call__(self, event: str, args: tuple[Any, ...]) -> None:
        if not self.active() or getattr(self._checking, "busy", False):
            return
        # The checks resolve paths, which may audit events of their own.
        self._checking.busy = True
        try:
            self._check(event, args)
        finally:
            self._checking.busy = False

    def _check(self, event: str, args: tuple[Any, ...]) -> None:
        if event == "open":
            path, mode, flags = args
            write = any(c in (mode or "") for c in "wax+") or bool(
                (flags or 0) & _WRITE_FLAGS
            )
            self._path(path, "write" if write else "read")
        elif event in _PATH_EVENTS:
            for path, access in zip(args, _PATH_EVENTS[event], strict=False):
                self._path(path, access)
        elif event in _PROCESS_EVENTS:
            _deny("subprocess creation")
        elif event == "urllib.Request":
            url = str(args[0])
            if url.lower().startswith("file:"):
                _deny("read access", url)
            self._network(url)
        elif event in _NETWORK_EVENTS:
            self._network()

    def _path(self, path: Any, access: str) -> None:
        if path is None or isinstance(path, int):
            # A file descriptor was opened, and checked, by an earlier call.
            return
        name = os.fsdecode(os.fspath(path))
        if access == "entry":
            resolved, roots, access = _entry(name), self.write_roots, "write"
        else:
            resolved = _canonical(name)
            roots = self.write_roots if access == "write" else self.read_roots
        if not _within(resolved, roots):
            _deny(f"{access} access", name)

    def _network(self, target: str | None = None) -> None:
        if self.network == "none":
            _deny("network access", target)


def _deny(kind: str, target: str | None = None) -> None:
    detail = "" if target is None else f" to {target!r}"
    raise PermissionError(f"commons run_python guardrails denied {kind}{detail}")


def engage(
    read_roots: Iterable[str],
    write_roots: Iterable[str],
    *,
    network: str,
    active: Callable[[], bool],
) -> None:
    """Install the guardrails for the rest of this process's life.

    ``active`` says whether model code is running; the checks apply only
    then. An audit hook cannot be removed once added.
    """
    sys.addaudithook(
        Guardrails(read_roots, write_roots, network=network, active=active)
    )

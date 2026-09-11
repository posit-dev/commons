"""The macOS seatbelt the worker engages on itself.

Seatbelt's entry points are plain libSystem symbols, so ``ctypes`` reaches
them without a compiled extension. ``sandbox.h`` declares them deprecated
since 10.8 with no replacement for unentitled processes; that is the only
interface macOS offers, so it is the one used here.

The profile is the same one the Darwin branch of ``pkg-r/src/sandbox.c``
builds.
"""

from __future__ import annotations

import ctypes
import os
from collections.abc import Iterable, Sequence
from typing import Literal, get_args

__all__ = ["NetworkAccess", "engage_seatbelt", "seatbelt_profile"]

NetworkAccess = Literal["none", "full"]


def _check_root(path: str) -> None:
    if not os.path.isabs(path):
        raise ValueError(f"cannot sandbox: root {path!r} is not an absolute path")
    if '"' in path or "\\" in path:
        raise ValueError(
            f"cannot sandbox: root {path!r} contains a quote or backslash"
        )


def _expand(roots: Iterable[str]) -> list[str]:
    """Each root plus its symlink-free form, in order, without repeats."""
    expanded: list[str] = []
    for root in roots:
        _check_root(root)
        resolved = os.path.realpath(root)
        _check_root(resolved)
        expanded += (root, resolved)
    return _unique(expanded)


def _unique(roots: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(roots))


def _subpaths(roots: Iterable[str]) -> str:
    return "".join(f' (subpath "{root}")' for root in roots)


def seatbelt_profile(
    read_roots: Sequence[str],
    write_roots: Sequence[str],
    *,
    network: NetworkAccess = "none",
) -> str:
    """Build the profile for these roots.

    Reads are granted under ``read_roots`` and writes under ``write_roots``,
    and write roots are granted for reading too. Both the original and the
    symlink-free form of every root are granted, because the sandbox matches
    resolved paths and macOS ``/tmp`` and ``/var`` live under ``/private``.
    """
    if network not in get_args(NetworkAccess):
        raise ValueError(f"unknown network access level {network!r}")

    readable = _expand(read_roots)
    writable = _expand(write_roots)
    # Later rules take precedence in SBPL, so each deny is followed by its
    # allowlist. file-read-metadata stays allowed for path traversal: it
    # exposes the existence of files outside the roots, but not contents.
    lines = ["(version 1)", "(allow default)"]
    if network == "none":
        lines.append("(deny network*)")
    lines.append("(deny file-write*)")
    # This allow always carries the /dev/null literal, so it is never the
    # unscoped rule the read allow above could become.
    lines.append(
        '(allow file-write* (literal "/dev/null")' + _subpaths(writable) + ")"
    )
    lines.append("(deny file-read*)")
    grantable = _unique(readable + writable)
    if grantable:
        # An allow with no path predicate would apply to everything, and it
        # comes after the deny, so with no roots the rule is left out rather
        # than emitted empty.
        lines.append("(allow file-read*" + _subpaths(grantable) + ")")
    lines.append("(allow file-read-metadata)")
    return "\n".join(lines) + "\n"


def engage_seatbelt(
    read_roots: Sequence[str],
    write_roots: Sequence[str],
    *,
    network: NetworkAccess = "none",
) -> None:
    """Restrict this process to the given roots, permanently.

    There is no way to lift a seatbelt profile once it is in place, which is
    the point: the worker calls this on itself before any model-written code
    is loaded.
    """
    profile = seatbelt_profile(read_roots, write_roots, network=network)

    libsystem = ctypes.CDLL(None)
    sandbox_init = libsystem.sandbox_init
    sandbox_init.argtypes = [
        ctypes.c_char_p,
        ctypes.c_uint64,
        ctypes.POINTER(ctypes.c_char_p),
    ]
    sandbox_init.restype = ctypes.c_int
    sandbox_free_error = libsystem.sandbox_free_error
    sandbox_free_error.argtypes = [ctypes.c_char_p]
    sandbox_free_error.restype = None

    error = ctypes.c_char_p()
    if sandbox_init(profile.encode(), 0, ctypes.byref(error)) != 0:
        # The message is seatbelt's own, and it is the only clue about which
        # rule it rejected.
        detail = (
            error.value.decode(errors="replace") if error.value else "unknown error"
        )
        sandbox_free_error(error)
        raise RuntimeError(f"sandbox_init failed: {detail}")

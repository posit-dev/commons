"""The Landlock filesystem sandbox, reached through ``ctypes``.

Landlock has no libc wrapper, so the three syscalls are made by number
through ``syscall()``.

``engage()`` restricts the calling process and cannot be undone, so importing
this module does nothing on its own. Enforcement afterwards is the kernel's,
not this code's.

``landlock_engage()`` in ``pkg-r/src/sandbox.c`` makes the same calls in the
same order.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import errno
import os
import platform
import sys
from collections.abc import Iterable

__all__ = [
    "FS_EXECUTE",
    "FS_IOCTL_DEV",
    "FS_MAKE_REG",
    "FS_READ_DIR",
    "FS_READ_FILE",
    "FS_READ_ONLY",
    "FS_REFER",
    "FS_REMOVE_FILE",
    "FS_TRUNCATE",
    "FS_WRITE_FILE",
    "PathBeneathAttr",
    "abi_version",
    "engage",
    "handled_access",
]

NR_CREATE_RULESET = 444
NR_ADD_RULE = 445
NR_RESTRICT_SELF = 446

# Those numbers come from the table most architectures share for syscalls
# added since 2019, but not all: mips offsets its whole table by thousands,
# so 444 there is a different call entirely. Calling a syscall by the wrong
# number is worse than not calling it, so this is an allowlist of the
# architectures the numbers are known to hold for, and anything else reports
# no Landlock and falls back.
KNOWN_ARCHITECTURES = frozenset({"x86_64", "amd64", "aarch64", "arm64"})

CREATE_RULESET_VERSION = 1 << 0
RULE_PATH_BENEATH = 1

PR_SET_NO_NEW_PRIVS = 38

# Defined here rather than read from ``os``, which only carries it on Linux,
# alongside the other kernel constants this module spells out.
O_PATH = 0o10000000

FS_EXECUTE = 1 << 0
FS_WRITE_FILE = 1 << 1
FS_READ_FILE = 1 << 2
FS_READ_DIR = 1 << 3
FS_REMOVE_FILE = 1 << 5
FS_MAKE_REG = 1 << 8
# Every right ABI 1 defines, which is bits 0 through 12.
FS_V1_ALL = (1 << 13) - 1
FS_REFER = 1 << 13
FS_TRUNCATE = 1 << 14
FS_IOCTL_DEV = 1 << 15

# What a read root is granted. Running a file counts as reading it, and a
# directory has to be listable for an import to find anything in it.
FS_READ_ONLY = FS_EXECUTE | FS_READ_FILE | FS_READ_DIR

# A kernel that has no Landlock, or that is behind a policy forbidding it,
# is a kernel to fall back from rather than fail on.
_UNAVAILABLE = frozenset({errno.ENOSYS, errno.EOPNOTSUPP, errno.EPERM})


class RulesetAttr(ctypes.Structure):
    """The ABI 1 ruleset attribute.

    Later versions append fields for network rights and scoping. The struct
    is extensible and read at the size it is given, so passing this one asks
    for a filesystem-only ruleset on any kernel.
    """

    _fields_ = (("handled_access_fs", ctypes.c_uint64),)


class PathBeneathAttr(ctypes.Structure):
    """One rule: an access mask and the directory it applies beneath.

    Packed, and 12 bytes rather than the 16 natural alignment would give.
    The kernel checks the size it was handed against its own definition.
    """

    _pack_ = 1
    _fields_ = (
        ("allowed_access", ctypes.c_uint64),
        ("parent_fd", ctypes.c_int32),
    )


# Syscall numbers are per-kernel and per-architecture, so making these calls
# anywhere else would not fail to find Landlock, it would invoke whatever
# that number means on the host instead. Everything below therefore refuses
# to run outside the pairs the numbers are known for, rather than trusting
# the call to come back with ENOSYS.
ON_LINUX = sys.platform == "linux" and platform.machine().lower() in (
    KNOWN_ARCHITECTURES
)

_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True) if ON_LINUX else None
if _libc is not None:
    # syscall() returns long; ctypes would otherwise truncate to int.
    _libc.syscall.restype = ctypes.c_long


def _syscall(number: int, *args: object) -> int:
    """Make a raw syscall, returning its result and leaving errno set.

    ``argtypes`` is left unset and every argument passed explicitly typed,
    because ``syscall()`` is variadic, and ctypes would otherwise promote
    values by its own rules rather than the kernel's.
    """
    assert _libc is not None
    ctypes.set_errno(0)
    return _libc.syscall(ctypes.c_long(number), *args)


def _set_no_new_privs() -> None:
    """Give up the ability to gain privileges, as Landlock requires.

    Landlock refuses to restrict an unprivileged process that could still
    become privileged through a setuid binary. Seccomp needs the same flag
    and setting it twice is harmless, so it belongs with whichever
    restriction runs first rather than in a caller both have to remember.
    """
    assert _libc is not None
    ctypes.set_errno(0)
    if _libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0):
        code = ctypes.get_errno()
        raise OSError(code, f"prctl(PR_SET_NO_NEW_PRIVS) failed: {os.strerror(code)}")


def handled_access(abi: int) -> int:
    """Every filesystem right a ruleset should handle on this ABI.

    Landlock leaves a right the ruleset does not handle entirely
    unrestricted, so the mask grows with the ABI the kernel reports rather
    than being fixed at one version's rights. ABI 4 adds network rights,
    which a filesystem ruleset does not handle, so it adds nothing here.

    ABI 5 is the newest that adds a filesystem right. A kernel reporting
    more than that is handled as 5, which means a filesystem right added by
    some later ABI would go unhandled, and therefore unrestricted, until
    this table learns about it. ABI 6, 7 and 8 exist and add none, so the
    table is complete today; kata `ctv9` tracks re-checking it. Declining
    Landlock on an unrecognised ABI was considered and rejected: it would
    give up a working sandbox on every future kernel to guard against a
    right that does not exist yet.
    """
    handled = FS_V1_ALL
    if abi >= 2:
        handled |= FS_REFER
    if abi >= 3:
        handled |= FS_TRUNCATE
    if abi >= 5:
        handled |= FS_IOCTL_DEV
    return handled


def abi_version() -> int:
    """The Landlock ABI this kernel reports, or ``-1`` where there is none."""
    if not ON_LINUX:
        return -1
    version = _syscall(
        NR_CREATE_RULESET, ctypes.c_void_p(None), ctypes.c_size_t(0),
        ctypes.c_uint32(CREATE_RULESET_VERSION)
    )
    return version if version >= 0 else -1


def _grant(ruleset_fd: int, path: str, access: int) -> None:
    """Add one path-beneath rule, or do nothing if the path is not there.

    A missing root is skipped rather than fatal. The read roots are the
    places an interpreter might keep its libraries and which of them exist
    varies by host, so refusing to start over one would be a sandbox that
    fails into not running at all. Not granting a path can only narrow what
    the worker reaches.
    """
    try:
        parent = os.open(path, O_PATH | os.O_CLOEXEC)
    except FileNotFoundError:
        return
    try:
        rule = PathBeneathAttr(allowed_access=access, parent_fd=parent)
        if _syscall(
            NR_ADD_RULE,
            ctypes.c_int(ruleset_fd),
            ctypes.c_int(RULE_PATH_BENEATH),
            ctypes.byref(rule),
            ctypes.c_uint32(0),
        ):
            raise OSError(
                ctypes.get_errno(),
                f"landlock_add_rule failed for {path!r}: "
                f"{os.strerror(ctypes.get_errno())}",
            )
    finally:
        os.close(parent)


def _roots(paths: Iterable[str]) -> list[str]:
    """Each path, what it resolves to, and where its entries lead.

    Landlock matches the hierarchy a path resolves to, not the path as
    written, so a rule naming a symlink grants nothing about the content
    behind it. Connect gives a deployed application a package library whose
    entries are symlinks into a shared store, and granting the library
    directory alone leaves every package in it unreadable. Resolving one
    level down is what covers that, and it is the same level
    ``worker_init()`` resolves in pkg-r.

    Deeper than one level is not walked: a store is granted whole once its
    first entry points into it, and walking a large tree at startup would
    cost more than the rules it produced.
    """
    resolved: dict[str, None] = {}
    for path in paths:
        resolved[path] = None
        resolved[os.path.realpath(path)] = None
        try:
            entries = os.scandir(path)
        except OSError:
            # Unreadable or absent roots simply grant nothing.
            continue
        with entries:
            for entry in entries:
                if entry.is_symlink():
                    resolved[os.path.realpath(entry.path)] = None
    return list(resolved)


def engage(read_roots: Iterable[str], write_roots: Iterable[str]) -> int | None:
    """Restrict this process to ``read_roots`` and ``write_roots``.

    Returns the ABI version the restriction was built for. Returns ``None``
    when this kernel has no Landlock to engage, which is the caller's signal
    to try another backend rather than an error: the user-namespace sandbox
    covers kernels too old for this one.

    Raises ``OSError`` when a kernel that does have Landlock refuses a step,
    since that is a broken host rather than an old one.

    Read roots are granted execute, read-file and read-dir. Write roots are
    granted everything the ruleset handles. Once this returns, nothing can
    widen the process's access again, including anything it goes on to
    execute.
    """
    abi = abi_version()
    if abi < 1:
        return None

    _set_no_new_privs()

    handled = handled_access(abi)
    attr = RulesetAttr(handled_access_fs=handled)
    ruleset_fd = _syscall(
        NR_CREATE_RULESET,
        ctypes.byref(attr),
        ctypes.c_size_t(ctypes.sizeof(attr)),
        ctypes.c_uint32(0),
    )
    if ruleset_fd < 0:
        code = ctypes.get_errno()
        if code in _UNAVAILABLE:
            return None
        raise OSError(
            code, f"landlock_create_ruleset failed: {os.strerror(code)}"
        )

    try:
        for path in _roots(read_roots):
            _grant(ruleset_fd, path, FS_READ_ONLY)
        for path in _roots(write_roots):
            _grant(ruleset_fd, path, handled)
        if _syscall(NR_RESTRICT_SELF, ctypes.c_int(ruleset_fd), ctypes.c_uint32(0)):
            code = ctypes.get_errno()
            raise OSError(
                code, f"landlock_restrict_self failed: {os.strerror(code)}"
            )
    finally:
        os.close(ruleset_fd)
    return abi

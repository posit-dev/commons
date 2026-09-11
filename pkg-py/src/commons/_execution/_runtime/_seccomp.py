"""The seccomp filter the worker installs on itself, and the network block.

This runs in the child, after the filesystem sandbox and before any
model-written code is loaded. Its job is the part of the boundary a
filesystem sandbox cannot express: the syscalls that would let the worker
step out of that sandbox rather than read around it, and, when the caller
asked for no network, the syscalls that open a socket.

A seccomp filter matches raw syscall numbers, and those are per
architecture, so the number table below is per architecture too. The filter's
first act is to confirm the calling architecture is the one its numbers came
from, because a foreign ABI (the i386 compat ABI on an x86_64 kernel, say)
numbers its syscalls differently and would let a screened call through under
a number this filter reads as something else.

The same filter is built by ``seccomp_engage()`` and ``network_engage()`` in
``pkg-r/src/sandbox.c``, where the compiler supplies the numbers.
"""

from __future__ import annotations

import ctypes
import os
import pathlib
import platform
import struct
import subprocess
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal

__all__ = [
    "ARCHES",
    "NETWORK_SCREENED",
    "SCREENED",
    "Arch",
    "allow_all",
    "arch_for",
    "build_network_filter",
    "build_sandbox_filter",
    "current_arch",
    "engage",
    "seccomp_available",
    "set_no_new_privs",
]

# Syscalls that would let the worker escape the sandbox rather than read
# around it: debugging another process, or rearranging the mount namespace
# the sandbox is expressed in.
SCREENED = (
    "ptrace",
    "process_vm_readv",
    "process_vm_writev",
    "pidfd_getfd",
    "mount",
    "umount2",
    "pivot_root",
    "chroot",
    "unshare",
    "setns",
    "open_tree",
    "move_mount",
    "fsopen",
    "fsconfig",
    "fsmount",
    "fspick",
    "mount_setattr",
)


# Screened as well, on the architectures whose table still carries them.
SCREENED_WHERE_PRESENT = ("umount",)

# Syscalls that open a socket, screened only when the caller asked for no
# network. Separate from SCREENED because network access is a choice and
# escaping the sandbox is not.
NETWORK_SCREENED = ("socket", "socketcall", "io_uring_setup")


class SockFilter(ctypes.Structure):
    """One BPF instruction, ``struct sock_filter``."""

    _fields_ = (
        ("code", ctypes.c_uint16),
        ("jt", ctypes.c_uint8),
        ("jf", ctypes.c_uint8),
        ("k", ctypes.c_uint32),
    )


class SockFprog(ctypes.Structure):
    """A filter program handed to the kernel, ``struct sock_fprog``."""

    _fields_ = (
        ("len", ctypes.c_uint16),
        ("filter", ctypes.POINTER(SockFilter)),
    )


# The BPF subset the filters are built from: load a word at a fixed offset
# into seccomp_data, compare the accumulator against a constant, return a
# verdict.
BPF_LD_W_ABS = 0x00 | 0x00 | 0x20
BPF_JEQ_K = 0x05 | 0x10 | 0x00
BPF_JGE_K = 0x05 | 0x30 | 0x00
BPF_JSET_K = 0x05 | 0x40 | 0x00
BPF_RET_K = 0x06 | 0x00

# Offsets into struct seccomp_data, whose layout is fixed across
# architectures.
DATA_NR = 0
DATA_ARCH = 4
DATA_ARG0 = 16

SECCOMP_RET_ALLOW = 0x7FFF0000
_SECCOMP_RET_ERRNO = 0x00050000

EPERM = 1
ENOSYS = 38

DENY_EPERM = _SECCOMP_RET_ERRNO | EPERM
DENY_ENOSYS = _SECCOMP_RET_ERRNO | ENOSYS

CLONE_NEWNS = 0x00020000
CLONE_NEWCGROUP = 0x02000000
CLONE_NEWUTS = 0x04000000
CLONE_NEWIPC = 0x08000000
CLONE_NEWUSER = 0x10000000
CLONE_NEWPID = 0x20000000
CLONE_NEWNET = 0x40000000

NAMESPACE_FLAGS = (
    CLONE_NEWNS
    | CLONE_NEWCGROUP
    | CLONE_NEWUTS
    | CLONE_NEWIPC
    | CLONE_NEWUSER
    | CLONE_NEWPID
    | CLONE_NEWNET
)


@dataclass(frozen=True, kw_only=True)
class Arch:
    """One architecture's syscall numbering and its audit tag."""

    name: str
    audit_arch: int
    x32_bit: int | None = None
    syscalls: Mapping[str, int]


def _screen(program: list[SockFilter], nr: int, verdict: int) -> None:
    """Deny one syscall number, leaving the rest to later instructions."""
    program.append(SockFilter(code=BPF_JEQ_K, jt=0, jf=1, k=nr))
    program.append(SockFilter(code=BPF_RET_K, jt=0, jf=0, k=verdict))


def _preamble(arch: Arch) -> list[SockFilter]:
    """Confirm the caller's ABI, then load the syscall number.

    Everything after this compares against ``arch``'s numbers, so a call
    arriving under any other ABI has to be refused before the comparisons
    rather than misread by them.
    """
    program = [
        SockFilter(code=BPF_LD_W_ABS, jt=0, jf=0, k=DATA_ARCH),
        SockFilter(code=BPF_JEQ_K, jt=1, jf=0, k=arch.audit_arch),
        SockFilter(code=BPF_RET_K, jt=0, jf=0, k=DENY_EPERM),
        SockFilter(code=BPF_LD_W_ABS, jt=0, jf=0, k=DATA_NR),
    ]
    if arch.x32_bit is not None:
        # x32 shares the x86_64 audit tag but sets a high bit and indexes its
        # own table, so it clears the check above while numbering differently.
        program.append(SockFilter(code=BPF_JGE_K, jt=0, jf=1, k=arch.x32_bit))
        program.append(SockFilter(code=BPF_RET_K, jt=0, jf=0, k=DENY_EPERM))
    return program


def build_network_filter(arch: Arch) -> list[SockFilter]:
    """A filter that refuses every way of opening a socket."""
    program = _preamble(arch)
    for name in NETWORK_SCREENED:
        if name in arch.syscalls:
            _screen(program, arch.syscalls[name], DENY_EPERM)
    program.append(SockFilter(code=BPF_RET_K, jt=0, jf=0, k=SECCOMP_RET_ALLOW))
    return program


# Numbers read from each architecture's kernel headers rather than written
# from memory: they agree from 425 up and diverge below, and two neighbours
# disagree where it would be easy to assume otherwise (pivot_root is 217 on
# i386 and 218 on arm).
ARCHES: Mapping[str, Arch] = {
    "x86_64": Arch(
        name="x86_64",
        audit_arch=0xC000003E,
        x32_bit=0x40000000,
        syscalls={
            "ptrace": 101,
            "process_vm_readv": 310,
            "process_vm_writev": 311,
            "pidfd_getfd": 438,
            "mount": 165,
            "umount2": 166,
            "pivot_root": 155,
            "chroot": 161,
            "unshare": 272,
            "setns": 308,
            "open_tree": 428,
            "move_mount": 429,
            "fsopen": 430,
            "fsconfig": 431,
            "fsmount": 432,
            "fspick": 433,
            "mount_setattr": 442,
            "clone": 56,
            "clone3": 435,
            "socket": 41,
            "io_uring_setup": 425,
        },
    ),
    "aarch64": Arch(
        name="aarch64",
        audit_arch=0xC00000B7,
        syscalls={
            "ptrace": 117,
            "process_vm_readv": 270,
            "process_vm_writev": 271,
            "pidfd_getfd": 438,
            "mount": 40,
            "umount2": 39,
            "pivot_root": 41,
            "chroot": 51,
            "unshare": 97,
            "setns": 268,
            "open_tree": 428,
            "move_mount": 429,
            "fsopen": 430,
            "fsconfig": 431,
            "fsmount": 432,
            "fspick": 433,
            "mount_setattr": 442,
            "clone": 220,
            "clone3": 435,
            "socket": 198,
            "io_uring_setup": 425,
        },
    ),
    "i386": Arch(
        name="i386",
        audit_arch=0x40000003,
        syscalls={
            "ptrace": 26,
            "process_vm_readv": 347,
            "process_vm_writev": 348,
            "pidfd_getfd": 438,
            "mount": 21,
            "umount2": 52,
            # The one-argument umount predating umount2, which only the i386
            # table still carries.
            "umount": 22,
            "pivot_root": 217,
            "chroot": 61,
            "unshare": 310,
            "setns": 346,
            "open_tree": 428,
            "move_mount": 429,
            "fsopen": 430,
            "fsconfig": 431,
            "fsmount": 432,
            "fspick": 433,
            "mount_setattr": 442,
            "clone": 120,
            "clone3": 435,
            "socket": 359,
            # i386 alone still multiplexes the socket calls through one entry
            # point, so screening socket() by itself would leave a way to
            # open one.
            "socketcall": 102,
            "io_uring_setup": 425,
        },
    ),
    "arm": Arch(
        name="arm",
        audit_arch=0x40000028,
        syscalls={
            "ptrace": 26,
            "process_vm_readv": 376,
            "process_vm_writev": 377,
            "pidfd_getfd": 438,
            "mount": 21,
            "umount2": 52,
            "pivot_root": 218,
            "chroot": 61,
            "unshare": 337,
            "setns": 375,
            "open_tree": 428,
            "move_mount": 429,
            "fsopen": 430,
            "fsconfig": 431,
            "fsmount": 432,
            "fspick": 433,
            "mount_setattr": 442,
            "clone": 120,
            "clone3": 435,
            "socket": 281,
            "io_uring_setup": 425,
        },
    ),
}


def build_sandbox_filter(arch: Arch) -> list[SockFilter]:
    """A filter that refuses the syscalls which would undo the sandbox.

    Opening a socket is left alone here; that is the network block's call.
    """
    program = _preamble(arch)
    for name in (*SCREENED, *SCREENED_WHERE_PRESENT):
        if name in arch.syscalls:
            _screen(program, arch.syscalls[name], DENY_EPERM)

    # Report clone3 missing rather than forbidden, so glibc falls back to
    # clone(). clone3 carries its flags in a struct behind a pointer, and a
    # filter cannot dereference one, so its flags cannot be screened at all.
    _screen(program, arch.syscalls["clone3"], DENY_ENOSYS)

    # Threads are fine; a new namespace is not.
    program.append(SockFilter(code=BPF_JEQ_K, jt=0, jf=3, k=arch.syscalls["clone"]))
    program.append(SockFilter(code=BPF_LD_W_ABS, jt=0, jf=0, k=DATA_ARG0))
    program.append(SockFilter(code=BPF_JSET_K, jt=0, jf=1, k=NAMESPACE_FLAGS))
    program.append(SockFilter(code=BPF_RET_K, jt=0, jf=0, k=DENY_EPERM))

    program.append(SockFilter(code=BPF_RET_K, jt=0, jf=0, k=SECCOMP_RET_ALLOW))
    return program


# What each ``platform.machine()`` means at each pointer size. A 32-bit
# process finds its own name here without help, because the kernel reports
# i686 or armv8l to one rather than the 64-bit name. The pointer size is in
# the key for what it excludes: x32 is the one ABI that reports a 64-bit
# machine with 32-bit pointers, and it belongs to neither table, since its
# calls carry the x86_64 audit tag over its own syscall numbering. It gets
# no entry, so such a host is reported unsandboxable rather than handed a
# filter that would reject every call it makes.
_MACHINES: Mapping[tuple[str, int], str] = {
    ("x86_64", 8): "x86_64",
    ("amd64", 8): "x86_64",
    ("i386", 4): "i386",
    ("i486", 4): "i386",
    ("i586", 4): "i386",
    ("i686", 4): "i386",
    ("aarch64", 8): "aarch64",
    ("arm64", 8): "aarch64",
    ("armv6l", 4): "arm",
    ("armv7l", 4): "arm",
    ("armv8l", 4): "arm",
}

PR_SET_NO_NEW_PRIVS = 38
PR_SET_SECCOMP = 22
PR_GET_SECCOMP = 21
SECCOMP_MODE_FILTER = 2


def arch_for(machine: str, pointer_size: int) -> Arch | None:
    """The table for a machine name and pointer size, or ``None`` for neither.

    ``None`` is the fail-closed answer. A filter built from another
    architecture's numbers is worse than no filter, because it reads as
    protection while screening the wrong calls.
    """
    name = _MACHINES.get((machine.lower(), pointer_size))
    return None if name is None else ARCHES[name]


def current_arch() -> Arch | None:
    """The table for the process this is running in."""
    return arch_for(platform.machine(), struct.calcsize("P"))


def _libc() -> ctypes.CDLL:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.restype = ctypes.c_int
    return libc


def _a_filter_installs() -> bool:
    """Whether this process may install a filter, found out by installing one.

    Asking the kernel whether it has seccomp is a different question: a
    container profile can answer that and still refuse PR_SET_SECCOMP. The
    only reliable answer is to install an allow-all filter and see, and that
    has to happen in a child because a filter cannot be lifted afterwards.
    """
    if not sys.executable:
        return False
    probe = (
        f"import sys; sys.path.insert(0, {str(pathlib.Path(__file__).parent)!r}); "
        "import _seccomp; _seccomp.set_no_new_privs(); "
        "_seccomp._install(_seccomp.allow_all(), what='probe filter')"
    )
    try:
        # -I to match how the worker is launched, so a sitecustomize on the
        # host's PYTHONPATH cannot decide the answer. A timeout because this
        # runs while the agent is being built, and a probe that never came
        # back would hang that rather than report anything.
        completed = subprocess.run(
            [sys.executable, "-I", "-c", probe],
            capture_output=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return completed.returncode == 0


def allow_all() -> list[SockFilter]:
    """A filter that permits everything, for finding out whether one installs."""
    return [SockFilter(code=BPF_RET_K, jt=0, jf=0, k=SECCOMP_RET_ALLOW)]


def seccomp_available() -> bool:
    """Whether this host can hold the worker to a seccomp filter.

    Part of what makes a Linux host sandboxable at all, so an architecture
    with no table counts as unavailable rather than as a filter to skip.
    """
    if platform.system() != "Linux" or current_arch() is None:
        return False
    if _libc().prctl(PR_GET_SECCOMP, 0, 0, 0, 0) < 0:
        return False
    return _a_filter_installs()


def set_no_new_privs() -> None:
    """Give up ever gaining privilege, for this process and its children.

    The kernel will not let an unprivileged process install a seccomp filter
    without this, since a filter that made a setuid binary misbehave would
    otherwise be a way to gain privilege rather than give it up. Landlock
    wants it for the same reason, and it is safe to set twice.
    """
    libc = _libc()
    if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        code = ctypes.get_errno()
        raise OSError(code, f"prctl(PR_SET_NO_NEW_PRIVS) failed: {os.strerror(code)}")


def _install(program: list[SockFilter], *, what: str) -> None:
    """Install one filter program, permanently, on the calling process."""
    instructions = (SockFilter * len(program))(*program)
    fprog = SockFprog(len=len(program), filter=instructions)
    if _libc().prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ctypes.byref(fprog)) != 0:
        code = ctypes.get_errno()
        raise OSError(code, f"cannot install the {what}: {os.strerror(code)}")


def engage(*, network: Literal["none", "full"]) -> None:
    """Put the filters on this process, for the rest of its life.

    Filters stack and none of them can be lifted, so this runs once, in the
    worker, before any model-written code is loaded.
    """
    if network not in ("none", "full"):
        raise ValueError(f"unknown network access level {network!r}")
    arch = current_arch()
    if arch is None:
        raise RuntimeError(
            "commons cannot install a seccomp filter on "
            f"{platform.machine()}: the syscall numbers it would have to "
            "match are not known for this architecture."
        )
    set_no_new_privs()
    _install(build_sandbox_filter(arch), what="seccomp filter")
    if network == "none":
        _install(build_network_filter(arch), what="network block")

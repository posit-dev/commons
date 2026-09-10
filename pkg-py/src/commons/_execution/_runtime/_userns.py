"""The user-namespace and tmpfs sandbox, engaged by the worker on itself.

The Linux sandbox for kernels that cannot offer Landlock. The worker enters a
new user and mount namespace, pivots into a fresh tmpfs root, and binds back
only the roots it has been granted, so what it cannot see it cannot reach.
The same sequence is in ``userns_engage`` in pkg-r/src/sandbox.c.

Importing this module is harmless. Calling ``engage()`` is not, and cannot be
undone in the process that calls it.
"""

from __future__ import annotations

import ctypes
import errno
import fcntl
import os
import platform
import re
import stat
import warnings

__all__ = [
    "UsernsError",
    "UsernsUnavailable",
    "available",
    "engage",
    "map_ids",
    "mountinfo_paths",
    "path_in_roots",
]

CLONE_NEWNS = 0x00020000
CLONE_NEWUSER = 0x10000000

MS_RDONLY = 1
MS_NOSUID = 2
MS_NODEV = 4
MS_NOEXEC = 8
MS_REMOUNT = 32
MS_NOATIME = 1024
MS_NODIRATIME = 2048
MS_BIND = 4096
MS_REC = 16384
MS_PRIVATE = 1 << 18
MS_RELATIME = 1 << 21

MNT_DETACH = 2

PR_CAPBSET_DROP = 24
_CAP_VERSION_3 = 0x20080522

# statvfs numbers the flags a mount carries differently from mount() itself,
# so carrying them across a remount is a translation rather than a copy.
_ST_TO_MS = (
    (2, MS_NOSUID),
    (4, MS_NODEV),
    (8, MS_NOEXEC),
    (1024, MS_NOATIME),
    (2048, MS_NODIRATIME),
    (4096, MS_RELATIME),
)

# glibc exports neither of these, so they go through syscall(). A wrong
# number would call something else entirely, so an architecture that is not
# listed reports the sandbox unavailable rather than guessing.
_SYSCALLS = {
    "x86_64": {"pivot_root": 155, "capset": 126},
    "aarch64": {"pivot_root": 41, "capset": 91},
}

# What the worker pivots into, and where the host root hangs until it is
# detached. /tmp is the one directory guaranteed to exist to mount over, and
# nothing of the host's /tmp survives the pivot.
_SANDBOX_ROOT = "/tmp"
_OLD_ROOT = "/.commons-oldroot"

# mountinfo escapes space, tab, newline and backslash as three octal digits.
_OCTAL = re.compile(r"\\([0-7]{3})")


class UsernsUnavailable(OSError):
    """This host will not give the worker a user namespace.

    Raised only where nothing has changed yet, so the caller is free to
    report an unsupported host and carry on deciding what to do. Container
    seccomp profiles and a zeroed user.max_user_namespaces land here.
    """


class UsernsError(OSError):
    """A step failed once the process had already been changed.

    There is no recovering from this and no falling back: ``unshare()``
    cannot be undone, so the process is left in a namespace whose ids or
    mounts are not what they were meant to be. It must die.
    """


class _CapHeader(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]


class _CapData(ctypes.Structure):
    _fields_ = [
        ("effective", ctypes.c_uint32),
        ("permitted", ctypes.c_uint32),
        ("inheritable", ctypes.c_uint32),
    ]


_LIBC: ctypes.CDLL | None = None


def _libc() -> ctypes.CDLL:
    """The one libc handle, which is what makes the argtypes below stick.

    Each ``CDLL`` carries its own function prototypes and its own errno, so a
    fresh handle per call would set argtypes on an object nobody calls and
    read errno from a call nobody made.
    """
    global _LIBC
    if _LIBC is None:
        # The main program handle resolves libc symbols without naming a
        # soname, which differs between glibc and musl.
        _LIBC = ctypes.CDLL(None, use_errno=True)
        _LIBC.mount.restype = ctypes.c_int
        _LIBC.mount.argtypes = [
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_ulong,
            ctypes.c_char_p,
        ]
        _LIBC.umount2.restype = ctypes.c_int
        _LIBC.umount2.argtypes = [ctypes.c_char_p, ctypes.c_int]
        _LIBC.unshare.restype = ctypes.c_int
        _LIBC.unshare.argtypes = [ctypes.c_int]
        _LIBC.syscall.restype = ctypes.c_long
    return _LIBC


def _fail(kind: type[OSError], message: str) -> OSError:
    code = ctypes.get_errno()
    return kind(code, f"{message}: {os.strerror(code)}")


def _syscall_numbers() -> dict[str, int]:
    """The syscall numbers for this architecture, or refuse the host.

    Asked before anything is changed, never in the middle of engaging, so
    that an architecture commons has no numbers for is an unavailable host
    rather than a process left half-confined.
    """
    machine = os.uname().machine
    try:
        return _SYSCALLS[machine]
    except KeyError:
        raise UsernsUnavailable(
            0, f"commons does not know the syscall numbers for {machine}"
        ) from None


def _syscall(name: str, *args: object) -> int:
    return _libc().syscall(ctypes.c_long(_syscall_numbers()[name]), *args)


def _mount(
    source: str | None,
    target: str,
    fstype: str | None,
    flags: int,
    data: str | None,
) -> int:
    def encode(value: str | None) -> bytes | None:
        return None if value is None else value.encode()

    return _libc().mount(
        encode(source), target.encode(), encode(fstype), flags, encode(data)
    )


def _write_proc(path: str, content: str) -> None:
    """Write ``content`` to ``path`` in one call, as procfs requires.

    Failing here is a ``UsernsError`` rather than an unavailable host: these
    writes only happen after ``unshare()`` has already put the process in a
    new namespace, where it holds the overflow ids until they are mapped.
    """
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CLOEXEC)
        try:
            os.write(fd, content.encode())
        finally:
            os.close(fd)
    except OSError as exc:
        raise UsernsError(exc.errno, f"cannot write {path}: {exc.strerror}") from exc


def mountinfo_paths(mountinfo: str) -> list[str]:
    """Every mount point in ``/proc/self/mountinfo`` contents, unescaped.

    Read before the pivot, because a read-only root has to remount each mount
    nested under it as well: a locked child mount keeps its own flags and
    stays writable otherwise.
    """
    paths = []
    for line in mountinfo.splitlines():
        fields = line.split(" ", 5)
        if len(fields) < 5:
            continue
        paths.append(_OCTAL.sub(lambda m: chr(int(m.group(1), 8)), fields[4]))
    return paths


def path_in_roots(path: str, roots: list[str]) -> bool:
    """Whether ``path`` is one of ``roots`` or sits underneath one.

    What follows the root has to be nothing or a new component, so ``/foobar``
    is not treated as being under ``/foo``.
    """
    for root in roots:
        trimmed = root.rstrip("/")
        if not trimmed or path == trimmed or path.startswith(trimmed + "/"):
            return True
    return False


def map_ids() -> None:
    """Enter a new user and mount namespace, keeping the caller's ids.

    The ids are read first: between ``unshare()`` and the maps being written
    the process reports the overflow ids, so reading them afterwards would
    map the wrong pair.

    Raises ``UsernsUnavailable`` if the namespace is refused, and
    ``UsernsError`` if it is granted but the maps cannot be written.
    """
    uid = os.getuid()
    gid = os.getgid()
    if _libc().unshare(CLONE_NEWUSER | CLONE_NEWNS) != 0:
        raise _fail(UsernsUnavailable, "cannot create a user namespace")
    # An unprivileged process must give up setgroups before mapping a gid.
    _write_proc("/proc/self/setgroups", "deny")
    _write_proc("/proc/self/uid_map", f"{uid} {uid} 1")
    _write_proc("/proc/self/gid_map", f"{gid} {gid} 1")


def _remount_readonly(path: str) -> None:
    """Remount an already-bound path read-only, keeping the flags it has.

    A mount the worker inherited locked refuses a remount that would drop any
    of its existing restrictions, so they are read back and asked for again.
    """
    flags = MS_REMOUNT | MS_BIND | MS_RDONLY
    try:
        existing = os.statvfs(path).f_flag
    except OSError:
        existing = 0
    for st_flag, ms_flag in _ST_TO_MS:
        if existing & st_flag:
            flags |= ms_flag
    if _mount(None, path, None, flags, None) != 0:
        raise _fail(UsernsError, f"cannot make {path} read-only in the sandbox")


def _bind(root: str, readonly: bool, submounts: list[str]) -> None:
    """Bind one granted root back in from the host root, at its own path.

    The bind is recursive, or anything mounted under the root is replaced by
    the empty directory it was mounted on. That is also why a read-only root
    remounts each of those nested mounts: read-only does not reach them.
    """
    os.makedirs(root, mode=0o755, exist_ok=True)
    if _mount(_OLD_ROOT + root, root, None, MS_BIND | MS_REC, None) != 0:
        raise _fail(UsernsError, f"cannot bind {root} into the sandbox")
    if not readonly:
        return
    _remount_readonly(root)
    for submount in submounts:
        if root == "/" or submount.startswith(root + "/"):
            _remount_readonly(submount)


def _close_external_fds(
    read_roots: list[str], rw_roots: list[str], preserve_fds: list[int]
) -> None:
    """Close descriptors that point outside the granted roots.

    A descriptor opened before the pivot still reaches whatever it was opened
    on, so the mounts alone do not confine the worker. Sockets go
    unconditionally. A file or directory stays only if its path is under a
    granted root, and under a read-only root only if it was opened read-only.
    Pipes and the like are left alone: they carry the protocol.
    """
    scan_fd = os.open("/proc/self/fd", os.O_RDONLY | os.O_DIRECTORY)
    try:
        entries = os.listdir(scan_fd)
    finally:
        os.close(scan_fd)
    for entry in entries:
        if not entry.isdigit():
            continue
        fd = int(entry)
        if fd <= 2 or fd == scan_fd or fd in preserve_fds:
            continue
        try:
            mode = os.fstat(fd).st_mode
        except OSError:
            continue
        if stat.S_ISSOCK(mode):
            os.close(fd)
            continue
        if not (
            stat.S_ISREG(mode)
            or stat.S_ISDIR(mode)
            or stat.S_ISCHR(mode)
            or stat.S_ISBLK(mode)
        ):
            continue
        try:
            target = os.readlink(f"/proc/self/fd/{fd}")
            accmode = fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE
        except OSError:
            os.close(fd)
            continue
        readable = accmode == os.O_RDONLY and path_in_roots(target, read_roots)
        if not readable and not path_in_roots(target, rw_roots):
            os.close(fd)


def _drop_capabilities() -> None:
    """Give up every capability the new namespace handed out.

    A user namespace makes its creator fully capable inside it, which is what
    allows the mounts above; nothing after them needs that. The bounding set
    goes first, so the capabilities cannot come back across an exec.
    """
    libc = _libc()
    cap = 0
    while libc.prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) == 0:
        cap += 1
    if ctypes.get_errno() != errno.EINVAL:
        raise _fail(UsernsError, f"cannot drop capability {cap}")
    header = _CapHeader(version=_CAP_VERSION_3, pid=0)
    data = (_CapData * 2)()
    if _syscall("capset", ctypes.byref(header), ctypes.byref(data)) != 0:
        raise _fail(UsernsError, "cannot clear the sandbox capabilities")


def engage(
    read_roots: list[str], rw_roots: list[str], *, preserve_fds: list[int]
) -> None:
    """Confine this process to ``read_roots`` and ``rw_roots``, for good.

    Raises ``UsernsUnavailable`` when the namespace never appears, which
    means this host cannot run this sandbox and the caller should say so.
    Every later failure raises ``UsernsError``.
    """
    # Both preflights, because everything below this point is irreversible.
    _syscall_numbers()
    threads = len(os.listdir("/proc/self/task"))
    if threads != 1:
        raise UsernsUnavailable(
            0,
            f"cannot enter a user namespace from a process with {threads} "
            "threads; start the worker with OPENBLAS_NUM_THREADS=1 and "
            "OMP_NUM_THREADS=1",
        )
    read_roots = [root.rstrip("/") or "/" for root in read_roots]
    rw_roots = [root.rstrip("/") or "/" for root in rw_roots]
    cwd = os.getcwd()

    map_ids()

    # Cut mount propagation both ways before recording or changing anything.
    if _mount("none", "/", None, MS_PRIVATE | MS_REC, None) != 0:
        raise _fail(UsernsError, "cannot make / a private mount")
    with open("/proc/self/mountinfo") as handle:
        submounts = mountinfo_paths(handle.read())
    _close_external_fds(read_roots, rw_roots, preserve_fds)

    if _mount("tmpfs", _SANDBOX_ROOT, "tmpfs", 0, "size=16m,mode=0755") != 0:
        raise _fail(UsernsError, "cannot mount the sandbox root tmpfs")

    # Pivot before binding, so the granted roots stay reachable through the
    # old root while they are being bound back in.
    os.mkdir(_SANDBOX_ROOT + _OLD_ROOT, 0o755)
    pivoted = _syscall(
        "pivot_root",
        _SANDBOX_ROOT.encode(),
        (_SANDBOX_ROOT + _OLD_ROOT).encode(),
    )
    if pivoted != 0:
        raise _fail(UsernsError, "cannot pivot into the sandbox root")
    os.chdir("/")

    for root in read_roots:
        _bind(root, True, submounts)
    for root in rw_roots:
        _bind(root, False, submounts)

    if _libc().umount2(_OLD_ROOT.encode(), MNT_DETACH) != 0:
        raise _fail(UsernsError, "cannot detach the host root")
    os.rmdir(_OLD_ROOT)
    if _mount(None, "/", None, MS_REMOUNT | MS_BIND | MS_RDONLY, None) != 0:
        raise _fail(UsernsError, "cannot make the sandbox root read-only")
    try:
        os.chdir(cwd)
    except OSError:
        # A working directory that was not granted leaves the worker at the
        # sandbox root, rather than the sandbox failing to engage.
        pass
    _drop_capabilities()


def available() -> bool:
    """Whether a child of this process could create a user namespace.

    Asked in a throwaway fork, not here. ``unshare(CLONE_NEWUSER)`` refuses a
    multi-threaded process, and a fork child is always single-threaded
    however many threads its parent is running, so probing in place would
    report the thread count rather than the host's policy. The child only
    makes syscalls before ``_exit``, so it cannot deadlock on a lock held at
    fork time, which is what Python warns about here.

    Answers ``False`` for every reason a namespace does not appear, because
    the caller does the same thing in each case.
    """
    if platform.system() != "Linux":
        return False
    try:
        _syscall_numbers()
    except UsernsUnavailable:
        return False
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            pid = os.fork()
    except OSError:
        return False
    if pid == 0:  # pragma: no cover - runs only in the child
        try:
            map_ids()
        except BaseException:  # noqa: BLE001 - the child reports by exit status
            os._exit(1)
        os._exit(0)
    try:
        _, status = os.waitpid(pid, 0)
    except OSError:
        return False
    return os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0

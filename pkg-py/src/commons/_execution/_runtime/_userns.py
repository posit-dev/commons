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

PR_SET_NO_NEW_PRIVS = 38
PR_CAPBSET_DROP = 24

# Carried as a number like the syscall table above: os.O_PATH exists only on
# Linux, and the module has to import everywhere.
_O_PATH = 0o10000000
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
    """The sandbox cannot be engaged from this process, and nothing changed.

    Raised only where the process is still as it was, so the caller is free
    to report the refusal and decide what to do. Some refusals are the
    host's policy -- container seccomp profiles, a zeroed
    user.max_user_namespaces, an architecture with no known syscall
    numbers -- and some are the caller's to fix, like engaging from a
    multi-threaded process. The message says which.
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
        _LIBC.prctl.restype = ctypes.c_int
        _LIBC.prctl.argtypes = [ctypes.c_int] + [ctypes.c_ulong] * 4
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
        # fsencode, so a mount point that is not UTF-8 survives the round
        # trip from mountinfo back to mount().
        return None if value is None else os.fsencode(value)

    return _libc().mount(
        encode(source), target.encode(), encode(fstype), flags, encode(data)
    )


def _write_proc(path: str, content: str) -> None:
    """Write ``content`` to ``path`` in one call, as procfs requires.

    Failing here is a ``UsernsError`` rather than an unavailable host: these
    writes only happen after ``unshare()`` has already put the process in a
    new namespace, where it holds the overflow ids until they are mapped.
    """
    data = content.encode()
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CLOEXEC)
        try:
            written = os.write(fd, data)
        finally:
            os.close(fd)
    except OSError as exc:
        raise UsernsError(exc.errno, f"cannot write {path}: {exc.strerror}") from exc
    if written != len(data):
        raise UsernsError(errno.EIO, f"cannot write {path}: short write")


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
    on, so the mounts alone do not confine the worker. Sockets, directories
    and O_PATH descriptors go unconditionally: a kept directory descriptor
    anchors the detached host tree, and openat() relative to it climbs back
    out of the sandbox. Anything legitimate is reopenable after the pivot. A
    regular file stays only if its path is under a granted root, and under a
    read-only root only if it was opened read-only. Pipes and the
    anonymous-inode descriptors (epoll, inotify, eventfd) are left alone:
    the worker's protocol speaks over the pipes, and an anonymous inode has
    no path to check. Descriptors 0-2 are left alone on the launcher's
    promise that they are pipes, not files.
    """
    # Imported here rather than at module level so the module still imports
    # on Windows, where fcntl does not exist and this never runs.
    import fcntl

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
        if stat.S_ISSOCK(mode) or stat.S_ISDIR(mode):
            os.close(fd)
            continue
        if not (
            stat.S_ISREG(mode) or stat.S_ISCHR(mode) or stat.S_ISBLK(mode)
        ):
            continue
        try:
            target = os.readlink(f"/proc/self/fd/{fd}")
            flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        except OSError:
            os.close(fd)
            continue
        if flags & _O_PATH:
            os.close(fd)
            continue
        readable = (
            flags & os.O_ACCMODE == os.O_RDONLY
            and path_in_roots(target, read_roots)
        )
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


def _normalize_roots(roots: list[str], *, writable: bool) -> list[str]:
    """Validate and trim the granted roots, before anything has changed.

    A root has to be an absolute path that names something: ``""`` and
    ``"//"`` would otherwise collapse to ``/`` and grant the whole host
    filesystem. A read-write root also cannot be ``/`` or the sandbox root:
    the sandbox root is mounted where ``/tmp`` was and remounted read-only
    at the end, so either grant would come out read-only and the promise
    made here is one the engage cannot keep.
    """
    normalized = []
    for root in roots:
        if not root.startswith("/"):
            raise UsernsUnavailable(
                0, f"a granted root must be an absolute path, not {root!r}"
            )
        trimmed = root.rstrip("/") or "/"
        if trimmed == "/" and root != "/":
            raise UsernsUnavailable(
                0, f"a granted root must name a directory, not {root!r}"
            )
        if writable and trimmed in ("/", _SANDBOX_ROOT):
            raise UsernsUnavailable(
                0,
                f"{trimmed} cannot be granted read-write: the sandbox root "
                "is remounted read-only over it",
            )
        normalized.append(trimmed)
    return normalized


def _check_nesting(read_roots: list[str], rw_roots: list[str]) -> None:
    """Refuse a read-only grant that a read-write grant would swallow.

    Read roots are bound first, so a recursive read-write bind stacks over a
    read-only bind nested inside it and the nested grant comes out writable.
    The reverse nesting is safe: a read-write bind inside a read-only root
    mounts over it and stays writable.
    """
    for root in read_roots:
        for rw_root in rw_roots:
            if root.startswith(rw_root + "/"):
                raise UsernsUnavailable(
                    0,
                    f"read-only root {root} sits inside read-write root "
                    f"{rw_root} and would come out writable",
                )


def engage(
    read_roots: list[str], rw_roots: list[str], *, preserve_fds: list[int]
) -> None:
    """Confine this process to ``read_roots`` and ``rw_roots``, for good.

    Three preconditions, all checked before anything changes: Linux with
    /proc mounted (the thread count and the mount table come from it), a
    single-threaded process (``unshare(CLONE_NEWUSER)`` refuses one with
    threads, so the BLAS pools have to be pinned before they start), and
    running before the seccomp filter, which screens the mount, pivot_root
    and unshare calls this makes.

    Raises ``UsernsUnavailable`` when the namespace never appears, which
    means this host cannot run this sandbox and the caller should say so.
    Every later failure raises ``UsernsError``.
    """
    if platform.system() != "Linux":
        raise UsernsUnavailable(0, "the user-namespace sandbox is Linux-only")
    # Every check goes before map_ids(), the first irreversible step.
    _syscall_numbers()
    read_roots = _normalize_roots(read_roots, writable=False)
    rw_roots = _normalize_roots(rw_roots, writable=True)
    _check_nesting(read_roots, rw_roots)
    try:
        threads = len(os.listdir("/proc/self/task"))
        cwd = os.getcwd()
    except OSError as exc:
        raise UsernsUnavailable(
            exc.errno, f"cannot preflight the sandbox: {exc.strerror}"
        ) from exc
    if threads != 1:
        raise UsernsUnavailable(
            0,
            f"cannot enter a user namespace from a process with {threads} "
            "threads; start the worker with OPENBLAS_NUM_THREADS=1 and "
            "OMP_NUM_THREADS=1",
        )

    map_ids()

    try:
        _confine(read_roots, rw_roots, preserve_fds, cwd)
    except (UsernsError, UsernsUnavailable):
        raise
    except OSError as exc:
        raise UsernsError(
            exc.errno, f"cannot engage the sandbox: {exc.strerror}"
        ) from exc


def _confine(
    read_roots: list[str],
    rw_roots: list[str],
    preserve_fds: list[int],
    cwd: str,
) -> None:
    """The irreversible body of ``engage()``, entered in the new namespace.

    Every failure here leaves a process that cannot be recovered, so
    ``engage()`` reports whatever escapes as a ``UsernsError``.
    """
    # Keep a setuid binary from handing back what the sandbox took away. The
    # seccomp filter sets this too, but this mechanism should not depend on
    # the other one running.
    if _libc().prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        raise _fail(UsernsError, "cannot set no_new_privs")
    # Cut mount propagation both ways before recording or changing anything.
    if _mount("none", "/", None, MS_PRIVATE | MS_REC, None) != 0:
        raise _fail(UsernsError, "cannot make / a private mount")
    with open("/proc/self/mountinfo", "rb") as handle:
        submounts = mountinfo_paths(os.fsdecode(handle.read()))
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
    # Warm the libc handle in the parent, so the child's first call really
    # is a syscall and the fork-warning suppression stays honest.
    _libc()
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
    while True:
        try:
            _, status = os.waitpid(pid, 0)
            break
        except InterruptedError:
            continue
        except ChildProcessError:
            # The embedding application reaps children itself (SIGCHLD set
            # to SIG_IGN), so the probe's answer is unknowable; report the
            # host unusable rather than guess.
            return False
        except OSError:
            return False
    return os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0

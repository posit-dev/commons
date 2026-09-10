"""The user-namespace and tmpfs sandbox the worker engages on itself.

Two layers. The parsing and matching helpers are ordinary functions and are
tested everywhere. Engaging the sandbox is irreversible and Linux-only, so
those tests fork, and the child reports back over a pipe what the sandbox
would and would not let it do.

The behaviour matches ``userns_engage`` and its helpers in
pkg-r/src/sandbox.c.
"""

from __future__ import annotations

import errno
import json
import os
import sys
import threading
import time
import warnings
from collections.abc import Callable
from typing import Any

import pytest

from commons._execution._env import worker_env
from commons._execution._runtime import _userns
from commons._execution._runtime._userns import (
    UsernsError,
    UsernsUnavailable,
    engage,
    map_ids,
    mountinfo_paths,
    path_in_roots,
)
from commons._execution._sandbox import (
    SandboxCapabilities,
    needs_single_thread,
    sandbox_capabilities,
)

linux_only = pytest.mark.skipif(
    sys.platform != "linux", reason="the user-namespace sandbox is Linux-only"
)

# Whether a namespace can be created is the host's policy, not just the
# kernel's: a container running the default seccomp profile refuses, and so
# does a host with user.max_user_namespaces at zero. Tests that engage the
# sandbox skip there rather than fail, which is why they ask the probe.
requires_userns = pytest.mark.skipif(
    sys.platform != "linux" or not sandbox_capabilities().userns,
    reason="this host does not offer unprivileged user namespaces",
)


def error_code(exc: OSError) -> str:
    """The errno name, which reads better in an assertion than the number."""
    assert exc.errno is not None
    return errno.errorcode[exc.errno]


def in_child(fn: Callable[[int], Any]) -> Any:
    """Run ``fn`` in a forked child and return what it reports back.

    Everything here is irreversible in the process that does it, so it is
    done in a child that exits straight afterwards. ``fn`` is handed the
    write end of the pipe, which is the descriptor it must ask the sandbox
    to preserve if it wants to be able to answer at all.
    """
    read_fd, write_fd = os.pipe()
    with warnings.catch_warnings():
        # The child only makes syscalls and then _exit()s, so it never waits
        # on a lock another thread held at fork time, which is what the
        # warning is about. The test process is multi-threaded whatever this
        # module does: importing commons starts threads.
        warnings.simplefilter("ignore", DeprecationWarning)
        pid = os.fork()
    if pid == 0:  # pragma: no cover - runs only in the child
        os.close(read_fd)
        try:
            payload = {"value": fn(write_fd)}
        except BaseException as exc:  # noqa: BLE001 - reported over the pipe
            payload = {"error": f"{type(exc).__name__}: {exc}"}
        try:
            os.write(write_fd, json.dumps(payload).encode())
        finally:
            os._exit(0)
    os.close(write_fd)
    with os.fdopen(read_fd, "rb") as pipe:
        raw = pipe.read()
    os.waitpid(pid, 0)
    assert raw, "the child exited without reporting anything"
    reported = json.loads(raw)
    if "error" in reported:
        pytest.fail(f"the child failed: {reported['error']}")
    return reported["value"]


def test_mountinfo_paths_reads_the_mount_point_field() -> None:
    mountinfo = (
        "23 28 0:22 / /proc rw,nosuid,relatime shared:12 - proc proc rw\n"
        "24 28 0:5 / /sys rw,nosuid,relatime shared:2 - sysfs sysfs rw\n"
    )
    assert mountinfo_paths(mountinfo) == ["/proc", "/sys"]


def test_mountinfo_paths_unescapes_octal_sequences() -> None:
    # A mount point with a space in it arrives as \040, and the bind and
    # remount calls need the real path, not the escaped one.
    mountinfo = "31 28 0:30 / /mnt/my\\040disk rw,relatime - tmpfs tmpfs rw\n"
    assert mountinfo_paths(mountinfo) == ["/mnt/my disk"]


def test_path_in_roots_does_not_match_a_longer_sibling() -> None:
    # The prefix test is what decides whether an inherited descriptor is
    # closed, so /foobar must not pass as being under /foo.
    assert path_in_roots("/foo/file", ["/foo"])
    assert not path_in_roots("/foobar/file", ["/foo"])


@requires_userns
def test_map_ids_enters_a_new_user_namespace() -> None:
    def child(_write_fd: int) -> str:
        map_ids()
        return os.readlink("/proc/self/ns/user")

    assert in_child(child) != os.readlink("/proc/self/ns/user")


@requires_userns
def test_map_ids_keeps_the_caller_ids_rather_than_the_overflow_ids() -> None:
    # unshare() reports the overflow ids until the maps are written, so the
    # real ids have to be read before it and written back afterwards.
    def child(_write_fd: int) -> list[int]:
        map_ids()
        return [os.getuid(), os.getgid()]

    assert in_child(child) == [os.getuid(), os.getgid()]


def test_unavailable_is_reported_rather_than_raised_as_a_bare_oserror() -> None:
    assert issubclass(UsernsUnavailable, OSError)


@linux_only
def test_the_probe_agrees_with_what_a_child_can_actually_do() -> None:
    # Stated as an agreement rather than a fixed answer, because whether a
    # namespace can be created is the host's policy: a container with the
    # default seccomp profile refuses, and the same test has to pass there.
    def child(_write_fd: int) -> bool:
        try:
            map_ids()
        except OSError:
            return False
        return True

    assert sandbox_capabilities().userns == in_child(child)


@pytest.mark.skipif(sys.platform == "linux", reason="asks about other kernels")
def test_the_probe_reports_no_user_namespace_off_linux() -> None:
    assert sandbox_capabilities().userns is False


@requires_userns
def test_the_host_filesystem_is_gone_once_the_sandbox_is_engaged(tmp_path) -> None:
    granted = tmp_path / "granted"
    granted.mkdir()
    (granted / "note.txt").write_text("visible")

    def child(write_fd: int) -> dict[str, bool]:
        engage([str(granted)], [], preserve_fds=[write_fd])
        return {
            "granted": os.path.exists(f"{granted}/note.txt"),
            "host": os.path.exists("/etc/passwd"),
        }

    assert in_child(child) == {"granted": True, "host": False}


@requires_userns
def test_a_read_root_reads_but_does_not_write(tmp_path) -> None:
    root = tmp_path / "readable"
    root.mkdir()
    (root / "note.txt").write_text("visible")

    def child(write_fd: int) -> dict[str, object]:
        engage([str(root)], [], preserve_fds=[write_fd])
        try:
            with open(f"{root}/new.txt", "w") as handle:
                handle.write("nope")
            wrote = None
        except OSError as exc:
            wrote = error_code(exc)
        with open(f"{root}/note.txt") as handle:
            return {"read": handle.read(), "wrote": wrote}

    assert in_child(child) == {"read": "visible", "wrote": "EROFS"}


@requires_userns
def test_a_read_write_root_writes(tmp_path) -> None:
    root = tmp_path / "writable"
    root.mkdir()

    def child(write_fd: int) -> str:
        engage([], [str(root)], preserve_fds=[write_fd])
        with open(f"{root}/new.txt", "w") as handle:
            handle.write("written")
        with open(f"{root}/new.txt") as handle:
            return handle.read()

    assert in_child(child) == "written"


@requires_userns
def test_the_working_directory_survives_the_pivot(tmp_path) -> None:
    root = tmp_path / "work"
    root.mkdir()

    def child(write_fd: int) -> str:
        os.chdir(str(root))
        engage([], [str(root)], preserve_fds=[write_fd])
        return os.getcwd()

    assert in_child(child) == str(root)


@requires_userns
def test_a_working_directory_that_was_not_granted_leaves_the_worker_at_root(
    tmp_path,
) -> None:
    # Losing the working directory is not a reason to refuse to sandbox: the
    # sandbox root is a safe place to be left.
    granted = tmp_path / "granted"
    granted.mkdir()
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()

    def child(write_fd: int) -> str:
        os.chdir(str(elsewhere))
        engage([], [str(granted)], preserve_fds=[write_fd])
        return os.getcwd()

    assert in_child(child) == "/"


@requires_userns
def test_a_descriptor_opened_outside_the_granted_roots_is_closed(tmp_path) -> None:
    granted = tmp_path / "granted"
    granted.mkdir()
    outside = tmp_path / "secret.txt"
    outside.write_text("secret")

    def child(write_fd: int) -> str | None:
        leaked = os.open(str(outside), os.O_RDONLY)
        engage([str(granted)], [], preserve_fds=[write_fd])
        try:
            os.read(leaked, 6)
        except OSError as exc:
            return error_code(exc)
        return None

    assert in_child(child) == "EBADF"


@requires_userns
def test_a_descriptor_inside_a_granted_root_stays_open(tmp_path) -> None:
    granted = tmp_path / "granted"
    granted.mkdir()
    (granted / "note.txt").write_text("visible")

    def child(write_fd: int) -> str:
        kept = os.open(f"{granted}/note.txt", os.O_RDONLY)
        engage([str(granted)], [], preserve_fds=[write_fd])
        return os.read(kept, 7).decode()

    assert in_child(child) == "visible"


@requires_userns
def test_a_read_only_descriptor_is_not_kept_for_a_read_write_root(tmp_path) -> None:
    # The rule is about the path, not the mode: a descriptor under a
    # read-write root survives whichever way it was opened.
    root = tmp_path / "writable"
    root.mkdir()
    (root / "note.txt").write_text("visible")

    def child(write_fd: int) -> str:
        kept = os.open(f"{root}/note.txt", os.O_RDWR)
        engage([], [str(root)], preserve_fds=[write_fd])
        return os.read(kept, 7).decode()

    assert in_child(child) == "visible"


@linux_only
def test_engaging_from_a_threaded_process_names_the_variables_that_fix_it() -> None:
    def child(write_fd: int) -> str:
        thread = threading.Thread(target=lambda: time.sleep(30), daemon=True)
        thread.start()
        try:
            engage([], [], preserve_fds=[write_fd])
        except UsernsUnavailable as exc:
            return str(exc)
        return "no error"

    reported = in_child(child)
    assert "OPENBLAS_NUM_THREADS=1" in reported
    assert "OMP_NUM_THREADS=1" in reported


def _nested_mounts() -> dict[str, tuple[str, str]]:
    """One nested mount of each kind, keyed "file" and "dir".

    A nested mount is one sitting inside a plain directory, which is what
    makes its parent usable as a granted root. Which ones a host has differs,
    so they are discovered: a container image supplies /etc/hosts as a file
    and /sys/fs/cgroup as a directory.
    """
    with open("/proc/self/mountinfo") as handle:
        paths = mountinfo_paths(handle.read())
    mounts = set(paths)
    found: dict[str, tuple[str, str]] = {}
    for path in sorted(paths):
        parent = os.path.dirname(path)
        if parent in ("", "/") or parent in mounts:
            continue
        kind = "dir" if os.path.isdir(path) else "file"
        found.setdefault(kind, (parent, path))
    return found


def write_attempt(path: str) -> str | None:
    """Try to write at ``path``, and report the errno name if it is refused.

    A mount point is a file on some hosts and a directory on others, and
    opening a directory for writing fails with EISDIR whatever the mount
    flags say, so a directory is probed by the file it would contain.
    """
    target = os.path.join(path, "commons-write-probe") if os.path.isdir(path) else path
    try:
        with open(target, "a"):
            pass
    except OSError as exc:
        return error_code(exc)
    return None


@requires_userns
@pytest.mark.parametrize("kind", ["file", "dir"])
def test_a_mount_nested_under_a_read_root_comes_along_and_is_read_only(kind) -> None:
    # The bind has to be recursive or the nested mount is replaced by the
    # empty directory it covers, and read-only does not reach it on its own.
    found = _nested_mounts().get(kind)
    if found is None:
        pytest.skip(f"this host has no nested {kind} mount inside a plain directory")
    root, nested = found

    def child(write_fd: int) -> dict[str, object]:
        engage([root, "/proc"], [], preserve_fds=[write_fd])
        with open("/proc/self/mountinfo") as handle:
            present = nested in mountinfo_paths(handle.read())
        return {"present": present, "wrote": write_attempt(nested)}

    assert in_child(child) == {"present": True, "wrote": "EROFS"}


@requires_userns
def test_the_capabilities_the_namespace_granted_are_given_up() -> None:
    # A new user namespace makes its creator fully capable inside it, which
    # is what allows the mounts. Nothing after them needs that.
    def child(write_fd: int) -> dict[str, str]:
        engage(["/proc"], [], preserve_fds=[write_fd])
        wanted = ("CapEff", "CapBnd")
        with open("/proc/self/status") as handle:
            return {
                name: value.strip()
                for name, _, value in (line.partition(":") for line in handle)
                if name in wanted
            }

    assert in_child(child) == {
        "CapEff": "0000000000000000",
        "CapBnd": "0000000000000000",
    }


def test_the_single_thread_variables_are_set_only_when_asked() -> None:
    # unshare(CLONE_NEWUSER) refuses a multi-threaded process, and a BLAS
    # library starts its pool before the worker gets to engage anything.
    pinned = worker_env("/tmp/scratch", single_thread=True)
    assert pinned["OPENBLAS_NUM_THREADS"] == "1"
    assert pinned["OMP_NUM_THREADS"] == "1"
    default = worker_env("/tmp/scratch")
    assert "OPENBLAS_NUM_THREADS" not in default
    assert "OMP_NUM_THREADS" not in default




def test_thread_pinning_is_never_asked_for_off_linux() -> None:
    capabilities = SandboxCapabilities(
        landlock_abi=-1, seccomp=False, seatbelt=True, userns=False
    )
    assert needs_single_thread(capabilities, sysname="Darwin") is False


def test_a_failed_id_map_is_not_reported_as_an_unavailable_host() -> None:
    """The two failure modes are distinct types, because only one of them
    leaves a process that can still be asked to do something else."""
    assert not issubclass(UsernsError, UsernsUnavailable)
    assert not issubclass(UsernsUnavailable, UsernsError)


@pytest.mark.parametrize(
    "landlock_abi, seccomp, userns, expected",
    [
        (1, True, True, False),
        (0, True, True, True),
        (0, True, False, False),
        # No seccomp means protection_mode() refuses the host whatever the
        # filesystem sandbox offers, so pinning would buy nothing.
        (0, False, True, False),
    ],
)
def test_thread_pinning_is_asked_for_only_where_this_sandbox_is_the_one_used(
    landlock_abi, seccomp, userns, expected
) -> None:
    capabilities = SandboxCapabilities(
        landlock_abi=landlock_abi, seccomp=seccomp, seatbelt=False, userns=userns
    )
    assert needs_single_thread(capabilities, sysname="Linux") is expected


@linux_only
def test_the_probe_refuses_an_architecture_with_no_known_syscall_numbers(
    monkeypatch,
) -> None:
    # pivot_root and capset are reached by number, so an architecture that is
    # not in the table cannot be sandboxed however willing the kernel is.
    monkeypatch.setattr(_userns, "_SYSCALLS", {})
    assert _userns.available() is False


@requires_userns
def test_an_unknown_architecture_is_refused_before_the_namespace_is_entered(
    monkeypatch,
) -> None:
    # The refusal has to come first. Raising it after unshare() would report
    # an unavailable host from a process that has already been changed.
    monkeypatch.setattr(_userns, "_SYSCALLS", {})
    before = os.readlink("/proc/self/ns/user")

    def child(write_fd: int) -> dict[str, str]:
        try:
            engage([], [], preserve_fds=[write_fd])
        except UsernsUnavailable:
            return {"raised": "unavailable", "namespace": os.readlink("/proc/self/ns/user")}
        except UsernsError:
            return {"raised": "error", "namespace": os.readlink("/proc/self/ns/user")}
        return {"raised": "nothing", "namespace": os.readlink("/proc/self/ns/user")}

    assert in_child(child) == {"raised": "unavailable", "namespace": before}

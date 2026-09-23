"""The seccomp filter the worker installs on itself, and the network block.

The filter matches raw syscall numbers, so it carries a hand-written number
table per architecture. Most of what follows runs the filter programs through
a small BPF interpreter, which is what lets one machine check all four tables
rather than only the one it happens to be running on.
"""

from __future__ import annotations

import errno
import functools
import json
import pathlib
import platform
import socket
import subprocess
import sys
from collections.abc import Callable
from typing import TYPE_CHECKING

import pytest

RUNTIME_DIR = str(
    pathlib.Path(__file__).parent.parent / "src" / "commons" / "_execution" / "_runtime"
)

if TYPE_CHECKING:
    from commons._execution._runtime import _seccomp, _userns
else:
    # Imported by bare name from the runtime directory, the way the worker
    # imports them. The 32-bit CI legs run this file on a bare interpreter,
    # where importing commons would drag in dependencies that publish no
    # 32-bit wheels.
    sys.path.insert(0, RUNTIME_DIR)
    import _seccomp
    import _userns

ARCH_NAMES = ["x86_64", "aarch64", "i386", "arm"]


@pytest.mark.parametrize("name", ARCH_NAMES)
def test_every_screened_syscall_has_a_number_on_every_arch(name: str) -> None:
    arch = _seccomp.ARCHES[name]
    missing = sorted(set(_seccomp.SCREENED) - set(arch.syscalls))
    assert missing == []


def run_filter(
    program: list[_seccomp.SockFilter], *, arch: int, nr: int, arg0: int = 0
) -> int:
    """Return what the filter decides for one syscall.

    A reading of the BPF subset the filter is built from, which is how the
    tables for architectures this machine is not can still be checked.
    """
    data = {_seccomp.DATA_NR: nr, _seccomp.DATA_ARCH: arch, _seccomp.DATA_ARG0: arg0}
    accumulator = 0
    index = 0
    while True:
        assert 0 <= index < len(program), "a jump ran off the end of the filter"
        instruction = program[index]
        code, jt, jf, k = (
            instruction.code,
            instruction.jt,
            instruction.jf,
            instruction.k,
        )
        index += 1
        if code == _seccomp.BPF_LD_W_ABS:
            accumulator = data.get(k, 0)
        elif code == _seccomp.BPF_RET_K:
            return k
        elif code == _seccomp.BPF_JEQ_K:
            index += jt if accumulator == k else jf
        elif code == _seccomp.BPF_JGE_K:
            index += jt if accumulator >= k else jf
        elif code == _seccomp.BPF_JSET_K:
            index += jt if accumulator & k else jf
        else:  # pragma: no cover - a code the builders never emit
            raise AssertionError(f"unhandled BPF code {code}")


@pytest.mark.parametrize("name", ARCH_NAMES)
@pytest.mark.parametrize("syscall", _seccomp.NETWORK_SCREENED)
def test_the_network_filter_refuses_to_open_a_socket(
    name: str, syscall: str
) -> None:
    arch = _seccomp.ARCHES[name]
    if syscall not in arch.syscalls:
        # socketcall exists only on the i386 table.
        pytest.skip(f"the {name} table has no {syscall}")
    program = _seccomp.build_network_filter(arch)
    decision = run_filter(program, arch=arch.audit_arch, nr=arch.syscalls[syscall])
    assert decision == _seccomp.DENY_EPERM


@pytest.mark.parametrize("name", ARCH_NAMES)
def test_the_network_filter_denies_a_call_from_a_foreign_abi(name: str) -> None:
    """The number a foreign ABI opens a socket with is not one this table screens.

    Passing the native number here would prove nothing, because the filter
    denies that number whatever ABI it arrives under.
    """
    arch = _seccomp.ARCHES[name]
    # A number the native table does not screen for some other reason: 41 is
    # socket on x86_64 and pivot_root on aarch64, which would deny either way.
    other = next(
        a
        for a in _seccomp.ARCHES.values()
        if a.name != name and a.syscalls["socket"] not in arch.syscalls.values()
    )
    foreign_socket = other.syscalls["socket"]
    decision = run_filter(
        _seccomp.build_network_filter(arch),
        arch=other.audit_arch,
        nr=foreign_socket,
    )
    assert decision == _seccomp.DENY_EPERM


def test_the_network_filter_denies_the_x32_abi() -> None:
    arch = _seccomp.ARCHES["x86_64"]
    assert arch.x32_bit is not None
    decision = run_filter(
        _seccomp.build_network_filter(arch),
        arch=arch.audit_arch,
        nr=arch.x32_bit | arch.syscalls["socket"],
    )
    assert decision == _seccomp.DENY_EPERM


@pytest.mark.parametrize("name", ARCH_NAMES)
def test_the_network_filter_leaves_reading_a_file_alone(name: str) -> None:
    arch = _seccomp.ARCHES[name]
    decision = run_filter(
        _seccomp.build_network_filter(arch),
        arch=arch.audit_arch,
        nr=arch.syscalls["ptrace"],
    )
    assert decision == _seccomp.SECCOMP_RET_ALLOW


@pytest.mark.parametrize("name", ARCH_NAMES)
@pytest.mark.parametrize("syscall", _seccomp.SCREENED)
def test_the_sandbox_filter_denies_every_screened_syscall(
    name: str, syscall: str
) -> None:
    arch = _seccomp.ARCHES[name]
    decision = run_filter(
        _seccomp.build_sandbox_filter(arch),
        arch=arch.audit_arch,
        nr=arch.syscalls[syscall],
    )
    assert decision == _seccomp.DENY_EPERM


def test_the_sandbox_filter_denies_the_i386_only_umount() -> None:
    arch = _seccomp.ARCHES["i386"]
    decision = run_filter(
        _seccomp.build_sandbox_filter(arch),
        arch=arch.audit_arch,
        nr=arch.syscalls["umount"],
    )
    assert decision == _seccomp.DENY_EPERM


@pytest.mark.parametrize("name", ARCH_NAMES)
def test_clone3_reports_itself_missing_rather_than_forbidden(name: str) -> None:
    """ENOSYS sends glibc back to clone(), whose flags the filter can read.

    clone3 passes its flags in a struct behind a pointer, and a seccomp
    filter cannot follow a pointer, so a permitted clone3 would be a way to
    ask for a namespace unseen.
    """
    arch = _seccomp.ARCHES[name]
    decision = run_filter(
        _seccomp.build_sandbox_filter(arch),
        arch=arch.audit_arch,
        nr=arch.syscalls["clone3"],
    )
    assert decision == _seccomp.DENY_ENOSYS


# Every namespace flag the clone screen must refuse, pinned one by one so a
# flag dropped from the mask fails under its own name.
NAMESPACE_FLAGS = {
    "CLONE_NEWTIME": _seccomp.CLONE_NEWTIME,
    "CLONE_NEWNS": _seccomp.CLONE_NEWNS,
    "CLONE_NEWCGROUP": _seccomp.CLONE_NEWCGROUP,
    "CLONE_NEWUTS": _seccomp.CLONE_NEWUTS,
    "CLONE_NEWIPC": _seccomp.CLONE_NEWIPC,
    "CLONE_NEWUSER": _seccomp.CLONE_NEWUSER,
    "CLONE_NEWPID": _seccomp.CLONE_NEWPID,
    "CLONE_NEWNET": _seccomp.CLONE_NEWNET,
}


@pytest.mark.parametrize("name", ARCH_NAMES)
@pytest.mark.parametrize("flag", NAMESPACE_FLAGS.values(), ids=NAMESPACE_FLAGS.keys())
def test_clone_is_denied_when_it_asks_for_a_new_namespace(
    name: str, flag: int
) -> None:
    arch = _seccomp.ARCHES[name]
    decision = run_filter(
        _seccomp.build_sandbox_filter(arch),
        arch=arch.audit_arch,
        nr=arch.syscalls["clone"],
        arg0=flag,
    )
    assert decision == _seccomp.DENY_EPERM


@pytest.mark.parametrize("name", ARCH_NAMES)
def test_an_ordinary_clone_is_allowed(name: str) -> None:
    """Threads still have to work; it is namespaces the filter is refusing."""
    arch = _seccomp.ARCHES[name]
    decision = run_filter(
        _seccomp.build_sandbox_filter(arch),
        arch=arch.audit_arch,
        nr=arch.syscalls["clone"],
        arg0=0,
    )
    assert decision == _seccomp.SECCOMP_RET_ALLOW


@pytest.mark.parametrize("name", ARCH_NAMES)
def test_the_sandbox_filter_leaves_opening_a_socket_alone(name: str) -> None:
    """Whether a socket may be opened is the network block's decision."""
    arch = _seccomp.ARCHES[name]
    decision = run_filter(
        _seccomp.build_sandbox_filter(arch),
        arch=arch.audit_arch,
        nr=arch.syscalls["socket"],
    )
    assert decision == _seccomp.SECCOMP_RET_ALLOW


@pytest.mark.parametrize(
    ("machine", "pointer_size", "expected"),
    [
        ("x86_64", 8, "x86_64"),
        ("amd64", 8, "x86_64"),
        ("aarch64", 8, "aarch64"),
        ("arm64", 8, "aarch64"),
        ("i686", 4, "i386"),
        ("i386", 4, "i386"),
        ("armv7l", 4, "arm"),
        ("armv6l", 4, "arm"),
        ("armv8l", 4, "arm"),
        # x32 is the only thing that reports a 64-bit machine with 32-bit
        # pointers, and it is neither of the tables that pair might suggest.
        ("x86_64", 4, None),
        ("amd64", 4, None),
        ("aarch64", 4, None),
        # Fail closed: with no table there is no filter worth installing.
        ("riscv64", 8, None),
        ("s390x", 8, None),
        ("ppc64le", 8, None),
    ],
)
def test_the_arch_is_read_from_the_machine_and_the_pointer_size(
    machine: str, pointer_size: int, expected: str | None
) -> None:
    arch = _seccomp.arch_for(machine, pointer_size)
    assert (arch.name if arch is not None else None) == expected


def test_x32_gets_no_table_rather_than_the_i386_one() -> None:
    """x32 is 32-bit pointers over the x86_64 syscall table, not i386.

    Its calls carry the x86_64 audit tag and set the x32 bit, so the i386
    table would build a filter whose very first check rejects every syscall
    the process makes. A 32-bit i386 process is not this case: the kernel
    reports i686 to it, so it finds its own table.
    """
    assert _seccomp.arch_for("x86_64", 4) is None


def test_seccomp_is_unavailable_where_the_kernel_has_no_seccomp() -> None:
    if platform.system() == "Linux":
        pytest.skip("this host has a kernel that may well offer seccomp")
    assert _seccomp.seccomp_available() is False


linux_only = pytest.mark.skipif(
    platform.system() != "Linux", reason="seccomp is a Linux facility"
)

# Engaging for real needs a host that will let a filter be installed, which
# a Linux host is entitled not to be: a container profile can permit the
# query and refuse PR_SET_SECCOMP, and that is a host the probe is meant to
# report False for, not one the suite should fail on.
def needs_seccomp(test: Callable[..., None]) -> Callable[..., None]:
    """Skip at call time rather than at collection, as a mark would.

    The skip question costs a probe subprocess to answer, and a mark
    answers it at collection, spending the subprocess on every run of
    this file, even one that deselects every test here.
    """

    @functools.wraps(test)
    def wrapper(*args: object, **kwargs: object) -> None:
        if not _seccomp.seccomp_available():
            pytest.skip("this host does not let a seccomp filter be installed")
        test(*args, **kwargs)

    return wrapper

# A filter cannot be lifted once installed, so every one of these runs in an
# interpreter of its own. Reporting from inside the child is also the only
# honest way to see the effect: the parent is deliberately untouched.
ENGAGE = """
import json, sys
sys.path.insert(0, {runtime!r})
import _seccomp
_seccomp.engage(network={network!r})
result = {{}}
{body}
json.dump(result, sys.stdout)
"""


def engage_in_child(body: str, *, network: str = "none") -> dict[str, object]:
    completed = subprocess.run(
        [
            sys.executable,
            "-I",
            "-c",
            ENGAGE.format(runtime=RUNTIME_DIR, network=network, body=body),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout)


@needs_seccomp
def test_no_new_privs_is_set_before_the_filter_goes_on() -> None:
    """Seccomp refuses to install for an unprivileged process without it."""
    result = engage_in_child("result['status'] = open('/proc/self/status').read()")
    assert "NoNewPrivs:\t1" in str(result["status"])


@needs_seccomp
def test_a_socket_cannot_be_opened_under_no_network() -> None:
    result = engage_in_child(
        """
import socket
try:
    socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    result['error'] = None
except PermissionError as exc:
    result['error'] = exc.errno
""",
        network="none",
    )
    assert result["error"] == errno.EPERM


@needs_seccomp
def test_a_socket_opens_normally_under_full_network() -> None:
    result = engage_in_child(
        """
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    result['family'] = int(sock.family)
""",
        network="full",
    )
    assert result["family"] == int(socket.AF_INET)


UNSHARE = """
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
CLONE_NEWUSER = 0x10000000
result['rc'] = libc.unshare(CLONE_NEWUSER)
result['errno'] = ctypes.get_errno()
"""


def unshare_refused_without_any_filter() -> bool:
    """Whether this host refuses a new user namespace on its own.

    A container's own seccomp profile commonly does, and on such a host an
    assertion that unshare is refused would hold whatever this filter says.
    """
    completed = subprocess.run(
        [sys.executable, "-I", "-c", f"result = {{}}\n{UNSHARE}\nprint(result['rc'])"],
        capture_output=True,
        text=True,
        check=True,
    )
    return completed.stdout.strip() == "-1"


@needs_seccomp
@pytest.mark.parametrize("network", ["none", "full"])
def test_a_new_namespace_cannot_be_unshared(network: str) -> None:
    """The escape the filesystem sandbox cannot refuse on its own."""
    if unshare_refused_without_any_filter():
        pytest.skip("this host refuses a new user namespace with no filter on")
    result = engage_in_child(UNSHARE, network=network)
    assert result["rc"] == -1
    assert result["errno"] == errno.EPERM


CLONE_NEWTIME_PROBE = """
import ctypes, json, os, sys
sys.path.insert(0, {runtime!r})
import _seccomp, _userns

CLONE_NEWTIME = 0x00000080
SIGCHLD = 17
STACK_SIZE = 65536

libc = _seccomp._libc()
stack = ctypes.create_string_buffer(STACK_SIZE)
stack_top = ctypes.addressof(stack) + STACK_SIZE
clone_fn = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)


def leave_immediately(_):
    os._exit(0)
    return 0


def clone_with_newtime_bit():
    ctypes.set_errno(0)
    # The glibc clone() wrapper rather than the raw syscall, so the cloned
    # child is handed a working stack and can leave through the callback.
    pid = libc.clone(
        clone_fn(leave_immediately),
        ctypes.c_void_p(stack_top),
        CLONE_NEWTIME | SIGCHLD,
        None,
    )
    if pid > 0:
        # CLONE_NEWTIME (0x80) sits inside the low byte of clone's flags,
        # which is the exit signal, so the child reports signal 0x91 rather
        # than SIGCHLD and only __WALL will reap it.
        os.waitpid(pid, 0x40000000)
        return 0
    return ctypes.get_errno()


_userns.map_ids()
result = {{}}
result['unfiltered'] = clone_with_newtime_bit()
_seccomp.engage(network='full')
result['filtered'] = clone_with_newtime_bit()
json.dump(result, sys.stdout)
"""


@needs_seccomp
def test_clone_with_the_newtime_bit_set_is_refused() -> None:
    """The flag the namespace mask was missing, against the live kernel.

    The legacy clone ABI cannot create a time namespace: the kernel strips
    the CSIGNAL byte, the 0x80 bit included, from the flags before the
    namespace logic runs, so the live paths are unshare (screened outright)
    and clone3 (denied ENOSYS). What this test pins is the mask itself: a
    clone whose flags word has the CLONE_NEWTIME bit set is refused,
    whatever the kernel would have made of it. The probe still enters a
    user namespace first, so the test keeps its meaning on any kernel that
    honours the bit, where an unprivileged clone would earn the kernel's
    own EPERM and the filter's answer could not be told apart from it. The
    unfiltered clone has to succeed for the filtered one's EPERM to mean
    anything.
    """
    if not _userns.available():
        pytest.skip("this host does not offer unprivileged user namespaces")
    completed = subprocess.run(
        [sys.executable, "-I", "-c", CLONE_NEWTIME_PROBE.format(runtime=RUNTIME_DIR)],
        capture_output=True,
        text=True,
        check=True,
    )
    result = json.loads(completed.stdout)
    if result["unfiltered"] != 0:
        # A restrictive container profile can refuse the clone outright, and
        # on such a host the filter's effect cannot be shown.
        pytest.skip(
            "this host refuses the clone with no filter on "
            f"(errno {result['unfiltered']})"
        )
    assert result["filtered"] == errno.EPERM


@needs_seccomp
def test_threads_still_start_once_the_filter_is_on() -> None:
    """The clone rule screens namespace flags, not clone itself."""
    result = engage_in_child(
        """
import threading
seen = []
thread = threading.Thread(target=lambda: seen.append(True))
thread.start()
thread.join()
result['ran'] = seen == [True]
""",
    )
    assert result["ran"] is True


# prctl's own number, needed to build filters that refuse one prctl option
# while permitting the rest.
PRCTL = {"x86_64": 157, "aarch64": 167, "i386": 172, "arm": 172}

DENY_PRCTL_OPTION = """
import ctypes, json, sys
sys.path.insert(0, {runtime!r})
import _seccomp

arch = _seccomp.current_arch()
program = [
    _seccomp.SockFilter(code=_seccomp.BPF_LD_W_ABS, jt=0, jf=0, k=_seccomp.DATA_NR),
    _seccomp.SockFilter(code=_seccomp.BPF_JEQ_K, jt=0, jf=3, k={prctl}),
    _seccomp.SockFilter(code=_seccomp.BPF_LD_W_ABS, jt=0, jf=0, k=_seccomp.DATA_ARG0),
    _seccomp.SockFilter(code=_seccomp.BPF_JEQ_K, jt=0, jf=1, k={option}),
    _seccomp.SockFilter(code=_seccomp.BPF_RET_K, jt=0, jf=0, k=_seccomp.DENY_EPERM),
    _seccomp.SockFilter(
        code=_seccomp.BPF_RET_K, jt=0, jf=0, k=_seccomp.SECCOMP_RET_ALLOW
    ),
]
_seccomp.set_no_new_privs()
_seccomp._install(program, what="test filter")
json.dump(
    {{
        "kernel_answers": _seccomp._libc().prctl(_seccomp.PR_GET_SECCOMP, 0, 0, 0, 0),
        "available": _seccomp.seccomp_available(),
    }},
    sys.stdout,
)
"""


def _available_when_denied(option: str) -> dict:
    """seccomp_available()'s answer in a child whose profile refuses one option."""
    arch = _seccomp.current_arch()
    assert arch is not None
    completed = subprocess.run(
        [
            sys.executable,
            "-I",
            "-c",
            DENY_PRCTL_OPTION.format(
                runtime=RUNTIME_DIR, prctl=PRCTL[arch.name], option=option
            ),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout)


@needs_seccomp
def test_seccomp_is_unavailable_where_a_filter_cannot_be_installed() -> None:
    """Being able to ask the kernel about seccomp is not permission to use it.

    A restrictive container profile can answer PR_GET_SECCOMP and still
    refuse PR_SET_SECCOMP, and a host like that has to be reported
    unsandboxable at construction rather than at the first call.
    """
    result = _available_when_denied("_seccomp.PR_SET_SECCOMP")
    assert result["kernel_answers"] >= 0, "the kernel should still answer the query"
    assert result["available"] is False


@needs_seccomp
def test_seccomp_is_available_where_only_the_query_is_refused() -> None:
    """Refusing the query does not make the host unsandboxable.

    A profile can refuse PR_GET_SECCOMP while permitting the install, and
    the install is the capability the worker needs, so the probe trusts
    the child install attempt rather than the query.
    """
    result = _available_when_denied("_seccomp.PR_GET_SECCOMP")
    assert result["kernel_answers"] < 0, "the query itself is refused here"
    assert result["available"] is True


PIDFD_GETFD = """
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
ctypes.set_errno(0)
# Deliberately not a pidfd. Without the screen the kernel rejects the
# argument; with it the call never reaches the kernel at all.
result['rc'] = libc.syscall(438, -1, 0, 0)
result['errno'] = ctypes.get_errno()
"""


def pidfd_getfd_unfiltered() -> int:
    completed = subprocess.run(
        [sys.executable, "-I", "-c", f"result = {{}}\n{PIDFD_GETFD}\nprint(result['errno'])"],
        capture_output=True,
        text=True,
        check=True,
    )
    return int(completed.stdout.strip())


@needs_seccomp
def test_a_descriptor_cannot_be_taken_from_another_process() -> None:
    """pidfd_getfd() hands over an open descriptor, sandbox and all.

    Screening ptrace is not enough on its own: this reaches into another
    process of the same user by a different door, and what it brings back is
    a descriptor the filesystem sandbox never granted.
    """
    unfiltered = pidfd_getfd_unfiltered()
    if unfiltered != errno.EBADF:
        # An old kernel answers ENOSYS and a restrictive container profile
        # answers EPERM, and under either this would hold with no filter on.
        pytest.skip(f"this host refuses pidfd_getfd on its own (errno {unfiltered})")
    result = engage_in_child(PIDFD_GETFD)
    assert result["rc"] == -1
    assert result["errno"] == errno.EPERM


PTRACE = """
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
ctypes.set_errno(0)
# PTRACE_TRACEME asks the parent to trace this process. It needs no
# privilege, so without the filter it succeeds, and with it the call
# never reaches the kernel.
result['rc'] = libc.ptrace(0, 0, 0, 0)
result['errno'] = ctypes.get_errno()
"""


def ptrace_unfiltered_errno() -> int:
    completed = subprocess.run(
        [
            sys.executable,
            "-I",
            "-c",
            f"result = {{}}\n{PTRACE}\nprint(result['errno'])",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return int(completed.stdout.strip())


@needs_seccomp
def test_ptrace_is_refused_with_this_archs_table_number() -> None:
    """A live check on a table number the interpreter tests cannot pin.

    The interpreter tests feed each table its own numbers, so a
    mis-transcribed number passes them. Here the kernel decides:
    PTRACE_TRACEME succeeds with no filter on, and meets EPERM only if
    this architecture's table entry really is ptrace's number.
    """
    if ptrace_unfiltered_errno() != 0:
        # A container profile that already blocks ptrace makes this hold
        # whatever the filter says.
        pytest.skip("this host refuses ptrace with no filter on")
    result = engage_in_child(PTRACE)
    assert result["rc"] == -1
    assert result["errno"] == errno.EPERM


def test_only_i386_still_carries_the_legacy_umount() -> None:
    """ARM looks like it should have it too, and does not.

    ARM numbers its syscalls close to i386's old order, so 22 reads like
    umount there as well. It is reachable only through the obsolete OABI
    entry path: the EABI headers do not define ``__NR_umount``, and the
    kernel's ARM table marks 22 OABI-only, so an EABI process calling 22
    gets ENOSYS. Screening it would screen nothing.
    """
    carriers = {a.name for a in _seccomp.ARCHES.values() if "umount" in a.syscalls}
    assert carriers == {"i386"}


@linux_only
def test_the_probe_ignores_a_sitecustomize_on_the_host(tmp_path, monkeypatch) -> None:
    """The worker is launched isolated, and the probe has to match it.

    site.py imports sitecustomize from sys.path, PYTHONPATH included, before
    anything the probe does. Without isolation an unrelated file on the
    host's PYTHONPATH would decide whether this host looks sandboxable.
    """
    # The answer is cached, so each probe starts from a cleared cache;
    # otherwise the second call repeats the first without probing, and
    # the test says nothing.
    _seccomp.seccomp_available.cache_clear()
    before = _seccomp.seccomp_available()
    (tmp_path / "sitecustomize.py").write_text("raise SystemExit(3)\n")
    monkeypatch.setenv("PYTHONPATH", str(tmp_path))

    _seccomp.seccomp_available.cache_clear()
    assert _seccomp.seccomp_available() is before

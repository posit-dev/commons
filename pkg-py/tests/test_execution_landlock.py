"""The Landlock filesystem sandbox the worker engages on itself.

What matters about a sandbox is what the kernel refuses afterwards, so the
cases that count run a real interpreter on a real kernel and ask it to try
things. On a host that is not Linux that kernel comes from a container; where
neither can supply one they skip rather than assert something weaker.
"""

from __future__ import annotations

import ctypes
import functools
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys

import pytest

from commons._execution._runtime import _landlock

RUNTIME_DIR = str(pathlib.Path(_landlock.__file__).parent)

# Any Landlock-capable kernel would do. This image is small and matches the
# interpreter the package targets.
IMAGE = "python:3.13-slim"

ABI_PROBE = "import _landlock, sys; sys.exit(0 if _landlock.abi_version() >= 1 else 1)"


def _host_has_landlock() -> bool:
    return platform.system() == "Linux" and _landlock.abi_version() >= 1


@functools.cache
def _docker_has_landlock() -> bool:
    """Whether a container on this machine can reach Landlock.

    Asks the kernel through the same code under test rather than inferring it
    from a version string: a daemon can be running, and its kernel can still
    have Landlock compiled out or fenced off by a seccomp profile. The
    answer is bounded: a daemon that cannot reply within the timeout,
    image pull included, means skipping the container cases rather than
    hanging the run that asked.
    """
    if shutil.which("docker") is None:
        return False
    try:
        completed = subprocess.run(
            _docker_command(ABI_PROBE),
            capture_output=True,
            check=False,
            timeout=300,
        )
    except subprocess.TimeoutExpired:
        return False
    return completed.returncode == 0


def _docker_command(script: str) -> list[str]:
    return [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{RUNTIME_DIR}:/runtime:ro",
        "-e",
        "PYTHONPATH=/runtime",
        IMAGE,
        "python",
        "-c",
        script,
    ]


def run_on_a_landlock_kernel(script: str) -> dict:
    """Run ``script`` where Landlock exists, and read the JSON it prints.

    Prefers this host and falls back to a container, so the same case gives
    real coverage on a Linux CI runner and on a macOS laptop running Docker.
    """
    if _host_has_landlock():
        completed = subprocess.run(
            [sys.executable, "-c", script],
            env={"PYTHONPATH": RUNTIME_DIR},
            capture_output=True,
            text=True,
            check=True,
        )
    else:
        completed = subprocess.run(
            _docker_command(script), capture_output=True, text=True, check=True
        )
    return json.loads(completed.stdout)


@pytest.fixture(scope="module")
def landlock_kernel() -> None:
    """Skip the kernel cases unless a Landlock-capable kernel is reachable.

    A fixture rather than a mark, so the check runs only for a test that
    needs it: a mark's condition is evaluated at import, and the Docker
    half can pull an image into a run that merely collected this file on
    the way to an unrelated test.
    """
    if not (_host_has_landlock() or _docker_has_landlock()):
        pytest.skip(
            "no Landlock-capable kernel available, on this host or through Docker"
        )

# Reporting the exception's type rather than a bare "denied" keeps a case
# honest: a setup mistake surfaces as FileNotFoundError instead of passing as
# the refusal the test was hoping for.
ATTEMPT = """
def attempt(action):
    try:
        action()
    except OSError as error:
        return type(error).__name__
    return "allowed"


def read(directory):
    return attempt(lambda: open(os.path.join(directory, "existing.txt")).close())


def write(directory):
    return attempt(lambda: open(os.path.join(directory, "new.txt"), "w").close())
"""

PROBE = (
    """
import json, os, sys, tempfile
import _landlock

# A fresh base each run: these probes engage a sandbox they cannot undo, so
# they cannot clean up after themselves, and a fixed path would collide with
# the run before it.
base = tempfile.mkdtemp()
readable = os.path.join(base, "readable")
scratch = os.path.join(base, "scratch")
outside = os.path.join(base, "outside")
for directory in (readable, scratch, outside):
    os.makedirs(directory)
    with open(os.path.join(directory, "existing.txt"), "w") as handle:
        handle.write("contents")

# /usr is granted so the interpreter can still reach its own standard library
# once the ruleset is in force.
abi = _landlock.engage(["/usr", readable], [scratch])
"""
    + ATTEMPT
    + """
json.dump(
    {
        "abi": abi,
        "read_readable": read(readable),
        "write_readable": write(readable),
        "read_scratch": read(scratch),
        "write_scratch": write(scratch),
        "read_outside": read(outside),
        "write_outside": write(outside),
        "still_running": sum(range(11)),
    },
    sys.stdout,
)
"""
)


@pytest.fixture(scope="module")
def probe(landlock_kernel: None) -> dict:
    return run_on_a_landlock_kernel(PROBE)


def test_a_read_root_can_be_read_but_not_written(probe) -> None:
    assert probe["read_readable"] == "allowed"
    assert probe["write_readable"] == "PermissionError"


def test_the_write_root_can_be_both_read_and_written(probe) -> None:
    assert probe["read_scratch"] == "allowed"
    assert probe["write_scratch"] == "allowed"


def test_a_directory_in_no_rule_is_reachable_neither_way(probe) -> None:
    assert probe["read_outside"] == "PermissionError"
    assert probe["write_outside"] == "PermissionError"


def test_the_worker_keeps_running_once_restricted(probe) -> None:
    assert probe["still_running"] == 55


def test_engage_reports_the_abi_it_restricted_the_process_with(probe) -> None:
    assert probe["abi"] >= 1


SYMLINK_PROBE = (
    """
import json, os, sys, tempfile
import _landlock

# The shape Connect gives a deployed application: the library directory is
# real, and every package in it is a symlink into a store somewhere else.
base = tempfile.mkdtemp()
store = os.path.join(base, "store", "pkg")
library = os.path.join(base, "library")
scratch = os.path.join(base, "scratch")
os.makedirs(store)
os.makedirs(library)
os.makedirs(scratch)
with open(os.path.join(store, "existing.txt"), "w") as handle:
    handle.write("contents")
os.symlink(store, os.path.join(library, "pkg"))

# Only the library is granted, which is what a caller listing sys.path would
# pass. Reaching the package means resolving the entry beneath it.
_landlock.engage(["/usr", library], [scratch])
"""
    + ATTEMPT
    + """
json.dump(
    {
        "through_the_link": read(os.path.join(library, "pkg")),
        "at_the_store": read(store),
    },
    sys.stdout,
)
"""
)


def test_a_package_symlinked_into_a_store_is_readable_through_its_library(
    landlock_kernel: None,
) -> None:
    """Granting the library alone leaves every package in it unreadable.

    Landlock matches the hierarchy a path resolves to, so a rule naming the
    library grants nothing about a store its entries point into. This is
    the shape a Connect deployment has, and getting it wrong fails as an
    import error rather than as anything about sandboxing.
    """
    reported = run_on_a_landlock_kernel(SYMLINK_PROBE)
    assert reported["through_the_link"] == "allowed"
    assert reported["at_the_store"] == "allowed"


MISSING_ROOT_PROBE = (
    """
import json, os, sys, tempfile
import _landlock

base = tempfile.mkdtemp()
scratch = os.path.join(base, "scratch")
os.makedirs(scratch)
abi = _landlock.engage(["/usr", os.path.join(base, "not-here")], [scratch])
"""
    + ATTEMPT
    + """
json.dump({"abi": abi, "write_scratch": write(scratch)}, sys.stdout)
"""
)


def test_a_root_that_does_not_exist_is_skipped_rather_than_fatal(
    landlock_kernel: None,
) -> None:
    """Granting nothing can only narrow what the worker reaches.

    The read roots are a list of places an interpreter might keep its
    libraries, and which of them exist varies by host. A missing one that
    refused to start the worker would be a sandbox that fails open into not
    running at all.
    """
    reported = run_on_a_landlock_kernel(MISSING_ROOT_PROBE)
    assert reported["abi"] >= 1
    assert reported["write_scratch"] == "allowed"


def test_the_handled_mask_covers_every_right_the_abi_defines() -> None:
    """Landlock leaves any right the ruleset does not handle unrestricted.

    The mask therefore has to grow with the kernel rather than be fixed at
    whatever commons was written against.
    """
    v1 = _landlock.handled_access(1)
    assert v1 == (1 << 13) - 1
    assert _landlock.handled_access(2) == v1 | _landlock.FS_REFER
    assert _landlock.handled_access(3) == (
        v1 | _landlock.FS_REFER | _landlock.FS_TRUNCATE
    )
    # ABI 4 adds network rights, which a filesystem ruleset does not handle.
    assert _landlock.handled_access(4) == _landlock.handled_access(3)
    assert _landlock.handled_access(5) == (
        _landlock.handled_access(4) | _landlock.FS_IOCTL_DEV
    )


def test_an_abi_newer_than_this_code_knows_is_handled_as_the_newest_known(
) -> None:
    assert _landlock.handled_access(99) == _landlock.handled_access(5)


def test_the_rule_attribute_is_packed_as_the_kernel_reads_it() -> None:
    """Natural alignment would pad this to 16 and the kernel would reject it."""
    assert ctypes.sizeof(_landlock.PathBeneathAttr) == 12


def test_the_scoped_ruleset_attribute_matches_the_kernel_layout() -> None:
    attr = _landlock.ScopedRulesetAttr
    assert ctypes.sizeof(attr) == 24
    assert attr.handled_access_fs.offset == 0
    assert attr.handled_access_net.offset == 8
    assert attr.scoped.offset == 16


SCOPE_PROBE = """
import json, os, socket, sys, tempfile
import _landlock

base = tempfile.mkdtemp()
scratch = os.path.join(base, "scratch")
os.makedirs(scratch)

# Stands in for a host daemon.
name = "\\0commons-scope-probe"
daemon = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
daemon.bind(name)

abi = _landlock.engage(["/usr"], [scratch])
result = {"abi": abi}

client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
try:
    client.connect(name)
    result["preexisting"] = "allowed"
except OSError as error:
    result["preexisting"] = type(error).__name__

# A socket bound after scoping stays reachable.
own = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
own.bind("\\0commons-scope-own")
peer = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
try:
    peer.connect("\\0commons-scope-own")
    result["own"] = "allowed"
except OSError as error:
    result["own"] = type(error).__name__

json.dump(result, sys.stdout)
"""


def test_abstract_sockets_outside_the_domain_are_unreachable(
    landlock_kernel: None,
) -> None:
    reported = run_on_a_landlock_kernel(SCOPE_PROBE)
    # None means a policy forbade Landlock on this kernel.
    if reported["abi"] is None or reported["abi"] < _landlock.SCOPE_MIN_ABI:
        pytest.skip(
            "abstract-socket scoping needs Landlock ABI "
            f"{_landlock.SCOPE_MIN_ABI} (Linux 6.12); this kernel reports "
            f"{reported['abi']}"
        )
    assert reported["preexisting"] == "PermissionError"
    assert reported["own"] == "allowed"


def test_a_read_root_is_granted_no_right_that_changes_anything() -> None:
    assert _landlock.FS_READ_ONLY == (
        _landlock.FS_EXECUTE | _landlock.FS_READ_FILE | _landlock.FS_READ_DIR
    )
    assert _landlock.FS_READ_ONLY & _landlock.FS_WRITE_FILE == 0
    assert _landlock.FS_READ_ONLY & _landlock.FS_MAKE_REG == 0
    assert _landlock.FS_READ_ONLY & _landlock.FS_REMOVE_FILE == 0


def test_engage_reports_none_where_the_kernel_has_no_landlock(monkeypatch) -> None:
    """``None`` rather than an error is the signal to fall back to another
    backend.

    The answer is patched in rather than read from the host: on a kernel
    that does have Landlock, engaging for real would restrict this test
    process past what pytest can survive.
    """
    monkeypatch.setattr(_landlock, "abi_version", lambda: -1)
    assert _landlock.engage([], []) is None


def test_a_host_outside_the_known_architectures_reports_no_landlock(
    monkeypatch,
) -> None:
    """The syscall numbers hold only for the allowlisted architectures, so
    anywhere else must fall back rather than dial a number that means
    something else."""
    monkeypatch.setattr(_landlock, "ON_LINUX", False)
    assert _landlock.abi_version() == -1


def test_roots_of_no_paths_is_empty() -> None:
    assert _landlock._roots([]) == []


def test_roots_repeats_no_path(tmp_path) -> None:
    once = _landlock._roots([str(tmp_path)])
    assert _landlock._roots([str(tmp_path), str(tmp_path)]) == once


def test_an_absent_root_yields_itself_and_nothing_more(tmp_path) -> None:
    missing = str(tmp_path / "not-here")
    assert set(_landlock._roots([missing])) == {missing, os.path.realpath(missing)}


def test_roots_resolves_symlinked_entries_one_level_down(tmp_path) -> None:
    store = tmp_path / "store" / "pkg"
    store.mkdir(parents=True)
    library = tmp_path / "library"
    library.mkdir()
    (library / "pkg").symlink_to(store, target_is_directory=True)
    assert set(_landlock._roots([str(library)])) == {
        str(library),
        os.path.realpath(library),
        os.path.realpath(library / "pkg"),
    }

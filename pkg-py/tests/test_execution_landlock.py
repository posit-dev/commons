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
    have Landlock compiled out or fenced off by a seccomp profile.
    """
    if shutil.which("docker") is None:
        return False
    return (
        subprocess.run(
            _docker_command(ABI_PROBE), capture_output=True, check=False
        ).returncode
        == 0
    )


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


landlock_kernel = pytest.mark.skipif(
    not (_host_has_landlock() or _docker_has_landlock()),
    reason="no Landlock-capable kernel available, on this host or through Docker",
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
def probe() -> dict:
    return run_on_a_landlock_kernel(PROBE)


@landlock_kernel
def test_a_read_root_can_be_read_but_not_written(probe) -> None:
    assert probe["read_readable"] == "allowed"
    assert probe["write_readable"] == "PermissionError"


@landlock_kernel
def test_the_write_root_can_be_both_read_and_written(probe) -> None:
    assert probe["read_scratch"] == "allowed"
    assert probe["write_scratch"] == "allowed"


@landlock_kernel
def test_a_directory_in_no_rule_is_reachable_neither_way(probe) -> None:
    assert probe["read_outside"] == "PermissionError"
    assert probe["write_outside"] == "PermissionError"


@landlock_kernel
def test_the_worker_keeps_running_once_restricted(probe) -> None:
    assert probe["still_running"] == 55


@landlock_kernel
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


@landlock_kernel
def test_a_package_symlinked_into_a_store_is_readable_through_its_library(
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


@landlock_kernel
def test_a_root_that_does_not_exist_is_skipped_rather_than_fatal() -> None:
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


def test_a_read_root_is_granted_no_right_that_changes_anything() -> None:
    assert _landlock.FS_READ_ONLY == (
        _landlock.FS_EXECUTE | _landlock.FS_READ_FILE | _landlock.FS_READ_DIR
    )
    assert _landlock.FS_READ_ONLY & _landlock.FS_WRITE_FILE == 0
    assert _landlock.FS_READ_ONLY & _landlock.FS_MAKE_REG == 0
    assert _landlock.FS_READ_ONLY & _landlock.FS_REMOVE_FILE == 0

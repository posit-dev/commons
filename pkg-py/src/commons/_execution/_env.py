"""The environment the worker process is given.

A subprocess inherits its parent's environment by default, and the parent
holds API keys, session tokens, and database URLs that model-written code has
no business reading. The worker therefore starts from an allowlist rather than
from what happens to be set.
"""

from __future__ import annotations

import os
import shutil
import sys
from collections.abc import Sequence
from pathlib import Path

__all__ = ["in_container", "interpreter_warning", "worker_command", "worker_env"]

# Enough to find an interpreter, load its libraries, and produce readable
# text, and nothing else. LD_LIBRARY_PATH and DYLD_LIBRARY_PATH are the
# Linux and macOS spellings of the same dynamic-linker search path.
_KEEP = ("PATH", "LANG", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH")


def worker_env(scratch_dir: str, *, single_thread: bool = False) -> dict[str, str]:
    """Build the worker's environment from an allowlist of the parent's.

    ``scratch_dir`` must be an absolute path; it becomes the worker's
    ``HOME`` and ``TMPDIR``, and a relative or empty value would silently
    weaken the guarantee those two provide.

    ``single_thread`` pins the numerical thread pools, which the
    user-namespace sandbox needs because it cannot be engaged by a process
    that has already started one. ``needs_single_thread()`` decides.
    """
    if not os.path.isabs(scratch_dir):
        raise ValueError(f"scratch_dir must be an absolute path, got {scratch_dir!r}")
    env = {name: os.environ[name] for name in _KEEP if name in os.environ}
    env.update(
        {name: value for name, value in os.environ.items() if name.startswith("LC_")}
    )
    # Point the worker's idea of home and scratch space at a directory it is
    # allowed to have: with no sandbox engaged these are all that keep it out
    # of the user's dot files.
    env["HOME"] = scratch_dir
    env["TMPDIR"] = scratch_dir
    if single_thread:
        # Values commons chooses rather than parent variables it passes on,
        # so they are set here rather than added to the allowlist.
        env["OPENBLAS_NUM_THREADS"] = "1"
        env["OMP_NUM_THREADS"] = "1"
    return env


def worker_command(
    script: str, *args: str, executable: str = sys.executable
) -> Sequence[str]:
    """The argv that launches the worker.

    ``-I`` is not a hardening extra to be traded off; it belongs with the
    allowlist. Without it ``site`` imports ``usercustomize`` from the user site
    directory, which runs before the worker and can write excluded variables
    back into ``os.environ``. It does not reach the global site-packages,
    where a ``sitecustomize`` module or ``.pth`` file still runs;
    ``interpreter_warning()`` covers that residual. ``-u`` keeps the protocol
    channel unbuffered.

    ``executable`` defaults to the interpreter running commons, which is what
    makes the worker's installed packages match the host's.
    """
    return [executable, "-I", "-u", script, *args]


# Files a container runtime leaves behind, used to tell "this system Python is
# the image author's" from "this system Python is shared with other people".
_CONTAINER_MARKERS = ("/.dockerenv", "/run/.containerenv")


def _venv_includes_system_site(executable: str) -> bool | None:
    """Read ``pyvenv.cfg`` for ``executable``; ``None`` if it is not a venv."""
    # A bare name is looked up on PATH, so the warning inspects the same
    # interpreter a launch would find rather than one relative to the
    # caller's working directory.
    if not os.path.isabs(executable):
        executable = shutil.which(executable) or executable
        if not os.path.isabs(executable):
            return None
    # Deliberately not resolved: a virtual environment's bin/python is usually
    # a symlink to the interpreter it was built from, and following it lands on
    # that installation rather than on the environment being asked about.
    config = Path(executable).absolute().parent.parent / "pyvenv.cfg"
    try:
        text = config.read_text()
    except (OSError, UnicodeDecodeError):
        # A config that cannot be read or decoded means the interpreter's
        # startup hooks are unknown, not that this check should fail.
        return None
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key.strip() == "include-system-site-packages":
            return value.strip().lower() == "true"
    return False


def in_container() -> bool:
    """Whether this process looks like it is running inside an image."""
    return any(os.path.exists(marker) for marker in _CONTAINER_MARKERS)


def interpreter_warning(
    executable: str = sys.executable, *, containerised: bool | None = None
) -> str | None:
    """Say why this interpreter's startup hooks are not known, or ``None``.

    Isolated mode drops the user site directory but not the global one, so a
    ``.pth`` file in a shared installation's site-packages still runs before
    the worker does. Whoever can write there can therefore run code inside it.
    That is fine when the only person who can write there is the image author,
    and not fine on a machine shared with other people. Pass ``containerised``
    to state which case this is rather than let it be inferred.
    """
    includes_system_site = _venv_includes_system_site(executable)
    if includes_system_site is False:
        return None
    if in_container() if containerised is None else containerised:
        return None
    reason = (
        "is a virtual environment built with --system-site-packages"
        if includes_system_site
        else "is not a virtual environment, or its pyvenv.cfg cannot be read"
    )
    return (
        f"the code execution worker would run on {executable}, which {reason}, "
        "so commons cannot tell what runs at its startup. Anyone who can write "
        "to its site-packages can run code inside the worker. Use a virtual "
        "environment that excludes system packages, or a container image whose "
        "contents you control."
    )

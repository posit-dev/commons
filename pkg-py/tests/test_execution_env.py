"""What the worker process is allowed to inherit, and what it must not.

These launch real interpreters. The property under test is what a child
process can actually see, and an assertion about the contents of a dictionary
would not have caught the failure this guards against.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys

import pytest

from commons._execution._env import (
    interpreter_warning,
    worker_command,
    worker_env,
)

READ_SECRET = "import os; print(os.environ.get('COMMONS_TEST_SECRET'))"


def test_a_variable_outside_the_allowlist_does_not_reach_the_worker(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.setenv("COMMONS_TEST_SECRET", "sk-not-a-real-key")

    result = subprocess.run(
        [sys.executable, "-c", READ_SECRET],
        env=worker_env(str(tmp_path)),
        capture_output=True,
        text=True,
        check=True,
    )

    assert result.stdout.strip() == "None"


def test_home_and_tmpdir_point_at_the_scratch_directory(tmp_path) -> None:
    # Left pointing at the real home, the worker could read the user's dot
    # files and write anywhere they can write. Both are the scratch directory
    # so that code with no sandbox still has nowhere interesting to go.
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "import os; print(os.environ['HOME'], os.environ['TMPDIR'])",
        ],
        env=worker_env(str(tmp_path)),
        capture_output=True,
        text=True,
        check=True,
    )

    assert result.stdout.split() == [str(tmp_path), str(tmp_path)]


def _plant_usercustomize(executable: str, env: dict[str, str]) -> bool:
    """Put code in the interpreter's user site directory that restores the secret.

    Returns whether the interpreter would import it at all, so the test can
    say it was skipped rather than pass without having tried anything.
    """
    probe = subprocess.run(
        [
            executable,
            "-c",
            "import site; print(site.ENABLE_USER_SITE); print(site.getusersitepackages())",
        ],
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    enabled, _, directory = probe.stdout.partition("\n")
    if enabled.strip() != "True":
        return False
    target = pathlib.Path(directory.strip())
    target.mkdir(parents=True, exist_ok=True)
    (target / "usercustomize.py").write_text(
        "import os\nos.environ['COMMONS_TEST_SECRET'] = 'restored'\n"
    )
    return True


def test_startup_hooks_cannot_put_an_excluded_variable_back(
    tmp_path, monkeypatch
) -> None:
    # An allowlist alone is not enough. `site` imports `usercustomize` from the
    # user site directory before the worker runs, and that code can write
    # straight back into os.environ. Isolated mode is what closes it.
    monkeypatch.setenv("COMMONS_TEST_SECRET", "sk-not-a-real-key")
    # A virtual environment turns the user site directory off, so the hole
    # only opens on an interpreter like the one this venv was built from.
    # That is exactly the interpreter the note warns about running on.
    executable = getattr(sys, "_base_executable", None)
    if executable is None:
        pytest.skip("no non-virtual-environment interpreter to test against")
    env = worker_env(str(tmp_path))
    script = tmp_path / "worker.py"
    script.write_text(READ_SECRET + "\n")
    if not _plant_usercustomize(executable, env):
        pytest.skip("this interpreter does not import usercustomize")

    unguarded = subprocess.run(
        [executable, str(script)], env=env, capture_output=True, text=True, check=True
    )
    guarded = subprocess.run(
        worker_command(str(script), executable=executable),
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )

    # The control matters: without it a passing test proves nothing about -I.
    assert unguarded.stdout.strip() == "restored"
    assert guarded.stdout.strip() == "None"


def test_a_virtual_environment_without_system_packages_is_accepted() -> None:
    # The suite runs in exactly the kind of interpreter the design asks for.
    assert interpreter_warning() is None


def test_a_virtual_environment_that_includes_system_packages_is_flagged(
    tmp_path,
) -> None:
    # Isolated mode drops the user site directory, not the global one, so a
    # venv wired to the system site-packages is still exposed to anything
    # installed there.
    venv = tmp_path / "shared"
    subprocess.run(
        [
            sys.executable,
            "-m",
            "venv",
            "--system-site-packages",
            "--without-pip",
            str(venv),
        ],
        check=True,
        capture_output=True,
    )

    warning = interpreter_warning(str(venv / "bin" / "python"))

    assert warning is not None
    assert "system" in warning


def test_an_interpreter_outside_any_virtual_environment_is_flagged() -> None:
    # The interpreter this virtual environment was built from, which is not
    # itself inside one.
    executable = getattr(sys, "_base_executable", None)
    if executable is None:
        pytest.skip("no non-virtual-environment interpreter to test against")

    warning = interpreter_warning(executable)

    assert warning is not None
    assert executable in warning


def test_the_worker_keeps_what_it_needs_to_run(tmp_path, monkeypatch) -> None:
    # An allowlist that is too narrow fails differently but just as badly: the
    # worker cannot find an interpreter or mangles non-ASCII output.
    monkeypatch.setenv("LC_ALL", "en_US.UTF-8")

    env = worker_env(str(tmp_path))

    assert env["PATH"] == os.environ["PATH"]
    assert env["LC_ALL"] == "en_US.UTF-8"

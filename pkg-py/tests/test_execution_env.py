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

from commons._execution import _env
from commons._execution._env import (
    in_container,
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

    warning = interpreter_warning(str(venv / "bin" / "python"), containerised=False)

    assert warning is not None
    assert "system" in warning


def test_an_interpreter_outside_any_virtual_environment_is_flagged() -> None:
    # The interpreter this virtual environment was built from, which is not
    # itself inside one.
    executable = getattr(sys, "_base_executable", None)
    if executable is None:
        pytest.skip("no non-virtual-environment interpreter to test against")

    warning = interpreter_warning(executable, containerised=False)

    assert warning is not None
    assert executable in warning


def test_the_worker_keeps_what_it_needs_to_run(tmp_path, monkeypatch) -> None:
    # An allowlist that is too narrow fails differently but just as badly: the
    # worker cannot find an interpreter or mangles non-ASCII output.
    monkeypatch.setenv("LANG", "en_US.UTF-8")
    monkeypatch.setenv("LC_ALL", "en_US.UTF-8")
    monkeypatch.setenv("LD_LIBRARY_PATH", "/opt/lib")

    env = worker_env(str(tmp_path))

    assert env["PATH"] == os.environ["PATH"]
    assert env["LANG"] == "en_US.UTF-8"
    assert env["LC_ALL"] == "en_US.UTF-8"
    assert env["LD_LIBRARY_PATH"] == "/opt/lib"


def test_a_container_image_is_accepted_even_outside_a_virtual_environment() -> None:
    # In an image, the only person who can write to site-packages is whoever
    # built it, so a bare system interpreter is the expected arrangement
    # rather than a shared machine's.
    executable = getattr(sys, "_base_executable", None) or sys.executable

    assert interpreter_warning(executable, containerised=True) is None


def test_the_launch_command_runs_isolated_and_unbuffered() -> None:
    # The behavioural tests prove -I through a planted usercustomize, but they
    # skip when no suitable interpreter exists, and nothing behavioural would
    # catch a dropped -u or a reordered argv. This one cannot skip.
    assert list(worker_command("worker.py", "one", "two")) == [
        sys.executable,
        "-I",
        "-u",
        "worker.py",
        "one",
        "two",
    ]


def test_the_launch_command_uses_the_given_interpreter() -> None:
    assert list(worker_command("worker.py", executable="/opt/py/bin/python")) == [
        "/opt/py/bin/python",
        "-I",
        "-u",
        "worker.py",
    ]


def test_container_detection_follows_the_marker_files(tmp_path, monkeypatch) -> None:
    marker = tmp_path / ".dockerenv"
    monkeypatch.setattr(_env, "_CONTAINER_MARKERS", (str(marker),))

    assert in_container() is False
    marker.touch()
    assert in_container() is True


def test_an_inferred_container_suppresses_the_warning(tmp_path, monkeypatch) -> None:
    # With containerised left to inference, the marker files are what stand
    # between a shared machine and a silenced warning, so both outcomes need
    # to be reachable from the default call.
    executable = getattr(sys, "_base_executable", None)
    if executable is None:
        pytest.skip("no non-virtual-environment interpreter to test against")
    marker = tmp_path / ".containerenv"
    monkeypatch.setattr(_env, "_CONTAINER_MARKERS", (str(marker),))

    assert interpreter_warning(executable) is not None
    marker.touch()
    assert interpreter_warning(executable) is None


def test_a_pyvenv_cfg_that_is_not_text_means_unknown(tmp_path) -> None:
    # A corrupted or locale-encoded config must degrade to "startup hooks
    # unknown" — a warning — not raise out of an advisory check.
    (tmp_path / "pyvenv.cfg").write_bytes(b"home = /usr\n\xff\xfe not text\n")

    warning = interpreter_warning(str(tmp_path / "bin" / "python"), containerised=False)

    assert warning is not None


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        ("include-system-site-packages = true\n", True),
        ("include-system-site-packages=true\n", True),
        ("include-system-site-packages = TRUE\n", True),
        ("include-system-site-packages = false\n", False),
        ("include-system-site-packages = yes\n", False),
        ("home = /usr/local\n", False),
        ("a line without a separator\ninclude-system-site-packages = true\n", True),
    ],
)
def test_pyvenv_cfg_parsing(tmp_path, content, expected) -> None:
    # Real venvs are well-behaved; these pin the contract for configs written
    # by hand or by other tools.
    (tmp_path / "pyvenv.cfg").write_text(content)

    assert _env._venv_includes_system_site(str(tmp_path / "bin" / "python")) is expected


def test_a_missing_pyvenv_cfg_means_not_a_virtual_environment(tmp_path) -> None:
    assert _env._venv_includes_system_site(str(tmp_path / "bin" / "python")) is None


def test_a_bare_interpreter_name_is_found_on_path(tmp_path, monkeypatch) -> None:
    # The warning must inspect the interpreter a launch would actually find,
    # not a path relative to the caller's working directory.
    binary = tmp_path / "bin" / "python"
    binary.parent.mkdir()
    binary.touch()
    binary.chmod(0o755)
    (tmp_path / "pyvenv.cfg").write_text("include-system-site-packages = false\n")
    monkeypatch.setenv("PATH", str(tmp_path / "bin"))

    assert interpreter_warning("python", containerised=False) is None


def test_an_unfindable_interpreter_is_treated_as_unknown(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("PATH", str(tmp_path))

    warning = interpreter_warning("no-such-interpreter", containerised=False)

    assert warning is not None

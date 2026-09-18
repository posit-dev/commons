"""The address-space limit the worker puts on itself before it runs any code.

These run real interpreters. A limit is only worth having if the kernel
actually enforces it, which an assertion about the arguments passed to
``setrlimit`` cannot show.
"""

from __future__ import annotations

import errno
import json
import os
import pathlib
import resource
import subprocess
import sys

import pytest

from commons._execution import _runtime

RUNTIME_DIR = str(pathlib.Path(_runtime.__file__).parent)

GIB = 1024**3

# Reporting the limit from inside the child is the only way to see it: the
# parent's own limit is untouched, by design.
REPORT = """
import json, resource, sys
{pre}
import _limits
applied = _limits.apply_address_space_limit({request})
soft, hard = resource.getrlimit(resource.RLIMIT_AS)
json.dump({{"applied": applied, "soft": soft, "hard": hard}}, sys.stdout)
"""

REPORT_INHERITED = (
    "import json, resource, sys;"
    " json.dump(resource.getrlimit(resource.RLIMIT_AS), sys.stdout)"
)


def apply_in_child(request: str = "", pre: str = "") -> dict[str, int | None]:
    """Apply the limit in a fresh interpreter and report the limit in force.

    ``pre`` runs before the limit is applied, which is how a host that has
    already capped the worker is simulated.
    """
    completed = subprocess.run(
        [sys.executable, "-c", REPORT.format(pre=pre, request=request)],
        env={**os.environ, "PYTHONPATH": RUNTIME_DIR},
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout)


def cap_the_child(limit: int) -> str:
    """Child code that clamps address space before the limit is applied."""
    return f"resource.setrlimit(resource.RLIMIT_AS, ({limit}, {limit}))"


@pytest.fixture(scope="module")
def ceiling() -> int | None:
    """The tightest limit a fresh child already has, or ``None`` for no limit.

    Everything below is expressed relative to this: a host that already caps
    address space caps these tests too, and a case that assumed a fixed value
    would assert the host's configuration when it means to assert the code's.
    """
    reported = json.loads(
        subprocess.run(
            [sys.executable, "-c", REPORT_INHERITED],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    finite = [value for value in reported if value != resource.RLIM_INFINITY]
    return min(finite) if finite else None


@pytest.fixture(scope="module")
def lower(ceiling: int | None) -> int:
    """The limit the clamp cases pre-set on the child, chosen to be one the
    child can actually reach."""
    return 2 * GIB if ceiling is None else min(2 * GIB, ceiling // 2)


@pytest.fixture(scope="module")
def refusal_errno(lower: int) -> int | None:
    """The errno a fresh child gets from capping its address space, or
    ``None`` when the call succeeds.

    macOS accepts the call on some releases and rejects it with ``EINVAL`` on
    others, so this is a question about the running kernel; the platform name
    cannot answer it. A child refused for any other reason (a seccomp profile
    that blocks ``setrlimit``, say) may still enforce ``RLIMIT_AS``, and only
    an ``EINVAL`` refusal lets the no-cap test below conclude the kernel has
    no such limit.
    """
    probe = (
        "import errno, json, resource, sys\n"
        "try:\n"
        f"    resource.setrlimit(resource.RLIMIT_AS, ({lower}, {lower}))\n"
        "except ValueError:\n"
        "    result = errno.EINVAL\n"
        "except OSError as exc:\n"
        "    result = exc.errno\n"
        "else:\n"
        "    result = 0\n"
        "json.dump(result, sys.stdout)\n"
    )
    completed = subprocess.run(
        [sys.executable, "-c", probe],
        capture_output=True,
        text=True,
        check=True,
    )
    result = json.loads(completed.stdout)
    return result if result != 0 else None


def test_the_default_limit_is_eight_gibibytes_and_is_the_one_in_force(
    ceiling: int | None, refusal_errno: int | None
) -> None:
    if refusal_errno is not None:
        pytest.skip("this kernel does not enforce RLIMIT_AS")
    if ceiling is not None and ceiling < 8 * GIB:
        pytest.skip("this host already caps address space below the default")
    reported = apply_in_child()
    assert reported["applied"] == 8 * GIB
    assert reported["soft"] == 8 * GIB
    assert reported["hard"] == 8 * GIB


def test_a_lower_inherited_limit_is_not_raised(
    lower: int, refusal_errno: int | None
) -> None:
    if refusal_errno is not None:
        pytest.skip("this kernel does not enforce RLIMIT_AS")
    reported = apply_in_child(pre=cap_the_child(lower))
    assert reported["applied"] == lower
    assert reported["soft"] == lower


def test_a_request_below_the_inherited_limit_still_applies(
    lower: int, refusal_errno: int | None
) -> None:
    if refusal_errno is not None:
        pytest.skip("this kernel does not enforce RLIMIT_AS")
    reported = apply_in_child(request=str(lower // 2), pre=cap_the_child(lower))
    assert reported["applied"] == lower // 2


def test_a_kernel_that_refuses_the_limit_does_not_stop_the_worker(
    refusal_errno: int | None,
) -> None:
    """The worker runs on without the cap and still starts.

    The cap guards against a runaway allocation; the security boundary is the
    sandbox. A host without the cap is worth reporting and still worth running
    on. ``apply_in_child`` requires a clean exit, so reaching an answer at all
    is half of what this asserts.
    """
    if refusal_errno is None:
        pytest.skip("this kernel enforces RLIMIT_AS")
    if refusal_errno != errno.EINVAL:
        pytest.skip("this host refuses the call for a reason of its own")
    assert apply_in_child()["applied"] is None


def test_the_limit_module_does_not_import_commons() -> None:
    """It runs inside the worker, which has no ``commons`` on its path."""
    completed = subprocess.run(
        [
            sys.executable,
            "-c",
            "import _limits, sys; sys.exit('commons' in sys.modules)",
        ],
        env={**os.environ, "PYTHONPATH": RUNTIME_DIR},
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr

"""The address-space limit the worker puts on itself before it runs any code.

These run real interpreters. A limit is only worth having if the kernel
actually holds the process to it, and an assertion about the arguments passed
to ``setrlimit`` would not show that.
"""

from __future__ import annotations

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


def apply_in_child(request: str = "", pre: str = "") -> dict[str, int | None]:
    """Apply the limit in a fresh interpreter and report what stuck.

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


REPORT_INHERITED = (
    "import json, resource, sys;"
    " json.dump(resource.getrlimit(resource.RLIMIT_AS), sys.stdout)"
)


def inherited_ceiling() -> int | None:
    """The tightest limit a fresh child already has, or ``None`` for no limit.

    Everything below is expressed relative to this: a host that already caps
    address space caps these tests too, and a case that assumed otherwise
    would be asserting the host's configuration rather than the code's.
    """
    reported = json.loads(
        subprocess.run(
            [
                sys.executable,
                "-c",
                REPORT_INHERITED,
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    finite = [value for value in reported if value != resource.RLIM_INFINITY]
    return min(finite) if finite else None


CEILING = inherited_ceiling()

# The limit the clamp cases pre-set on the child, chosen to be one the child
# can actually reach.
LOWER = 2 * GIB if CEILING is None else min(2 * GIB, CEILING // 2)
LOWER_THE_LIMIT = f"resource.setrlimit(resource.RLIMIT_AS, ({LOWER}, {LOWER}))"


def address_space_is_settable() -> bool:
    """Whether this host lets a process cap its own address space at all.

    macOS accepts the call on some releases and rejects it with ``EINVAL`` on
    others, so this is a question about the running kernel rather than about
    the platform name.
    """
    completed = subprocess.run(
        [sys.executable, "-c", f"import resource; {LOWER_THE_LIMIT}"],
        capture_output=True,
        check=False,
    )
    return completed.returncode == 0


SETTABLE = address_space_is_settable()

settable = pytest.mark.skipif(
    not SETTABLE, reason="this kernel does not enforce RLIMIT_AS"
)


@settable
@pytest.mark.skipif(
    CEILING is not None and CEILING < 8 * GIB,
    reason="this host already caps address space below the default",
)
def test_the_default_limit_is_eight_gibibytes_and_is_the_one_in_force() -> None:
    reported = apply_in_child()
    assert reported["applied"] == 8 * GIB
    assert reported["soft"] == 8 * GIB
    assert reported["hard"] == 8 * GIB


@settable
def test_a_lower_inherited_limit_is_not_raised() -> None:
    reported = apply_in_child(pre=LOWER_THE_LIMIT)
    assert reported["applied"] == LOWER
    assert reported["soft"] == LOWER


@settable
def test_a_request_below_the_inherited_limit_still_applies() -> None:
    reported = apply_in_child(request=str(LOWER // 2), pre=LOWER_THE_LIMIT)
    assert reported["applied"] == LOWER // 2


@pytest.mark.skipif(SETTABLE, reason="this kernel enforces RLIMIT_AS")
def test_a_kernel_that_refuses_the_limit_does_not_stop_the_worker() -> None:
    """The worker runs on without the cap rather than failing to start.

    The cap guards against a runaway allocation; it is not the security
    boundary, which is the sandbox. A host without it is worth reporting, not
    worth refusing to run on. ``apply_in_child`` requires a clean exit, so
    reaching an answer at all is half of what this asserts.
    """
    assert apply_in_child()["applied"] is None


def test_the_limit_module_does_not_import_commons() -> None:
    """It runs inside the worker, which has no ``commons`` on its path."""
    completed = subprocess.run(
        [
            sys.executable,
            "-c",
            "import _limits, sys; sys.exit('commons' in sys.modules)",
        ],
        env={"PYTHONPATH": RUNTIME_DIR, "PATH": os.environ.get("PATH", "")},
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr

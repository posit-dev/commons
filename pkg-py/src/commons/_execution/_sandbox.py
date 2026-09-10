"""Whether this host can sandbox the worker, decided before anything runs.

The worker sandboxes itself, in the child, before any model-written code is
loaded. What lives here is the parent's half: a probe of what the host offers
and the gate that turns that into a refusal, so a host commons cannot protect
is reported when the agent is constructed rather than when a model first asks
to run code.

The same decision is made by ``run_r_protection_mode()`` in
``pkg-r/R/sandbox.R``.
"""

from __future__ import annotations

import ctypes
import os
import platform
from dataclasses import dataclass
from typing import Literal

from ._runtime import _seccomp

__all__ = [
    "ALLOW_UNSAFE_FALLBACK",
    "ProtectionMode",
    "SandboxCapabilities",
    "protection_mode",
    "sandbox_capabilities",
]

ProtectionMode = Literal["sandbox", "guardrails"]

# An environment variable rather than a constructor keyword: accepting weaker
# protection should take a deliberate act outside the code, not a keyword a
# caller can pass without noticing what it gives up.
ALLOW_UNSAFE_FALLBACK = "COMMONS_ALLOW_UNSAFE_FALLBACK"

_AFFIRMATIVE = frozenset({"1", "true", "yes", "on"})

_OPT_IN = (
    f"For local development only, set {ALLOW_UNSAFE_FALLBACK}=1 to accept "
    "best-effort guardrails, which are not a security boundary."
)


@dataclass(frozen=True, kw_only=True)
class SandboxCapabilities:
    """What the running kernel offers the worker.

    ``landlock_abi`` is the Landlock ABI version, ``0`` where the syscall
    exists but reports no usable version and ``-1`` where it does not exist.
    """

    landlock_abi: int
    seccomp: bool
    seatbelt: bool
    userns: bool


def _seatbelt_present() -> bool:
    """Whether libSystem here exports seatbelt's entry point.

    The symbol is looked up rather than inferred from the platform, so a
    macOS that ever drops these deprecated entry points reports no seatbelt
    instead of promising one the worker cannot engage. The worker repeats this
    check for itself; the parent must not import the module that engages it.
    """
    if platform.system() != "Darwin":
        return False
    try:
        return hasattr(ctypes.CDLL(None), "sandbox_init")
    except OSError:
        return False


def sandbox_capabilities() -> SandboxCapabilities:
    """Probe this host for each mechanism the worker can restrict itself with.

    Each field is filled in by the module that implements its mechanism.
    Landlock and user namespaces have no implementation yet and report
    unavailable until they do, so ``protection_mode()`` still refuses every
    Linux host: seccomp alone is not enough without a filesystem sandbox
    beside it, which is the safe direction to be wrong in while those are
    being built.
    """
    return SandboxCapabilities(
        landlock_abi=-1,
        seccomp=_seccomp.seccomp_available(),
        seatbelt=_seatbelt_present(),
        userns=False,
    )


def _guardrails_allowed() -> bool:
    return os.environ.get(ALLOW_UNSAFE_FALLBACK, "").strip().lower() in _AFFIRMATIVE


def protection_mode(
    capabilities: SandboxCapabilities | None = None,
    *,
    sysname: str | None = None,
) -> ProtectionMode:
    """How much the worker can be protected on this host.

    Returns ``"sandbox"`` when the host offers a real sandbox. Otherwise
    raises, unless guardrails have been opted into, in which case it returns
    ``"guardrails"``: a scratch-directory working directory, an address-space
    limit, and a warning. Guardrails are a way to keep working on a host
    commons cannot protect, not a weaker sandbox.

    ``capabilities`` and ``sysname`` default to this host; passing them is
    how the decision table is exercised from any machine. There is
    deliberately no argument for the opt-in: the only way to accept
    guardrails is to set the environment variable.
    """
    if capabilities is None:
        capabilities = sandbox_capabilities()
    if sysname is None:
        sysname = platform.system()

    if sysname == "Linux":
        available = capabilities.seccomp and (
            capabilities.landlock_abi >= 1 or capabilities.userns
        )
    elif sysname == "Darwin":
        available = capabilities.seatbelt
    else:
        available = False

    if available:
        return "sandbox"
    if _guardrails_allowed():
        return "guardrails"

    if sysname == "Linux" and not capabilities.seccomp:
        raise RuntimeError(
            "commons cannot sandbox the code execution worker because this "
            f"Linux host does not support seccomp. {_OPT_IN}"
        )
    if sysname == "Linux":
        raise RuntimeError(
            "commons cannot sandbox the code execution worker because this "
            "Linux host offers neither Landlock nor unprivileged user "
            "namespaces. Use a kernel with Landlock, or enable unprivileged "
            "user namespaces: check `sysctl user.max_user_namespaces` and, in "
            f"a container, its seccomp profile. {_OPT_IN}"
        )
    raise RuntimeError(
        f"commons cannot sandbox the code execution worker on {sysname}. {_OPT_IN}"
    )

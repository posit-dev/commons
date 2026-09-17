"""Whether this host can sandbox the worker, decided before anything runs.

The worker sandboxes itself, in the child, before any model-written code is
loaded. This module is the parent's half: a probe of what the host offers
and the gate that turns that into a refusal, so a host commons cannot protect
is reported when the agent is constructed rather than when a model first asks
to run code.

The same decision is made by ``run_r_protection_mode()`` in
``pkg-r/R/sandbox.R``.
"""

from __future__ import annotations

import os
import platform
from dataclasses import dataclass
from typing import Literal

__all__ = [
    "ALLOW_UNSAFE_FALLBACK",
    "ProtectionMode",
    "SandboxCapabilities",
    "protection_mode",
    "sandbox_capabilities",
]

# "sandbox" means the worker restricts itself with a kernel mechanism, so
# model-written code is genuinely contained. "guardrails" is the weaker
# fallback reachable only by opting in through ALLOW_UNSAFE_FALLBACK: it
# provides no security boundary.
ProtectionMode = Literal["sandbox", "guardrails"]

# Accepting weaker protection should take a deliberate act outside the code,
# so this opt-in lives in an environment variable: a constructor keyword is
# too easy for a caller to pass without noticing what it gives up.
ALLOW_UNSAFE_FALLBACK = "COMMONS_ALLOW_UNSAFE_FALLBACK"

_AFFIRMATIVE = frozenset({"1", "true", "yes", "on"})

_OPT_IN = (
    f"For local development only, set {ALLOW_UNSAFE_FALLBACK}=1 to accept "
    "best-effort guardrails; guardrails provide no security boundary!"
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


def sandbox_capabilities() -> SandboxCapabilities:
    """Probe this host for each mechanism the worker can restrict itself with.

    Each field is filled in by the ctypes module that implements its
    mechanism, none of which exist yet. Until they do this reports every
    mechanism unavailable, so ``protection_mode()`` refuses every host: the
    safe direction to be wrong in while the sandbox is being built.
    """
    return SandboxCapabilities(
        landlock_abi=-1, seccomp=False, seatbelt=False, userns=False
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
    ``"guardrails"``: the address-space limit today, with a scratch-directory
    working directory and a warning to come as the worker is built. Guardrails
    are a way to keep working on a host commons cannot protect; they provide
    no sandbox.

    ``capabilities`` and ``sysname`` default to this host; passing them is
    how the decision table is exercised from any machine, so leave both at
    their defaults outside the tests. There is deliberately no argument for
    the opt-in: the only way to accept guardrails is to set the environment
    variable.
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
            "namespaces. Use a kernel with Landlock. Unprivileged user "
            "namespaces work too, where the host accepts their larger kernel "
            "attack surface: check `sysctl user.max_user_namespaces` and, in "
            f"a container, its seccomp profile. {_OPT_IN}"
        )
    raise RuntimeError(
        f"commons cannot sandbox the code execution worker on {sysname}. {_OPT_IN}"
    )

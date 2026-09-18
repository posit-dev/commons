"""Whether this host can sandbox the worker, decided before anything runs.

The worker sandboxes itself, in the child, before any model-written code is
loaded. This module is the parent's half: a probe of what the host offers
and the gate that turns that into a refusal, so a host commons cannot protect
is reported when the agent is constructed, ahead of any model asking to run
code.

``run_r_protection_mode()`` in ``pkg-r/R/sandbox.R`` makes the same
decision, with two divergences. On macOS, R reports seatbelt from the
compile-time platform, so a macOS without these symbols would promise
"sandbox" there and fail at engage, where the runtime probe here refuses
at construction. On Linux, R asks the kernel whether seccomp exists, while
the probe here instead installs a filter in a child. A container profile
can answer that query while refusing the install: R reports such a host as
seccomp-capable and fails it at engage, and the probe here reports
it incapable and refuses at construction.
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


def _seatbelt_present() -> bool:
    """Whether libSystem here exports seatbelt's entry point.

    The symbol is looked up on the running host, so a macOS that ever drops
    these entry points reports no seatbelt. Inferring from the platform would
    promise a sandbox the worker cannot engage. The worker repeats this check
    for itself; the parent's copy stays here because a symbol lookup is cheap
    enough that repeating it beats importing the module that engages it.

    Note: ``sandbox_init`` has been officially deprecated (though still working)
    since macOS 10.8 (July 2012), with no replacement offered to unentitled
    processes; see ``man 3 sandbox_init``
    (https://keith.github.io/xcode-man-pages/sandbox_init.3.html). OpenAI's
    Codex CLI relies on the same deprecated interface to sandbox its agent on
    macOS (https://github.com/openai/codex/issues/215).
    """
    if platform.system() != "Darwin":
        return False
    try:
        return hasattr(ctypes.CDLL(None), "sandbox_init")
    except OSError:
        return False


def sandbox_capabilities() -> SandboxCapabilities:
    """Probe this host for each mechanism the worker can restrict itself with.

    Seatbelt support is a symbol lookup in libSystem. The seccomp probe
    installs a filter in a child process, so its answer is computed once
    and cached. Landlock and user namespaces have no implementation
    yet and report unavailable, so ``protection_mode()`` will still refuse
    every Linux host.
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
    ``"guardrails"``. Guardrails are a way to keep working on a host commons
    cannot protect; they provide no sandbox.

    ``capabilities`` and ``sysname`` default to this host; passing them is
    how the decision table is exercised from any machine, so leave both at
    their defaults outside the tests. There is deliberately no argument for
    the opt-in: the only way to accept guardrails is to set the environment
    variable defined in ``ALLOW_UNSAFE_FALLBACK``.
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
            "namespaces. Use a kernel with Landlock, or enable user "
            "namespaces with `sysctl user.max_user_namespaces` (some "
            "container seccomp profiles block them) and accept the larger "
            f"kernel attack surface. {_OPT_IN}"
        )
    raise RuntimeError(
        f"commons cannot sandbox the code execution worker on {sysname}. {_OPT_IN}"
    )

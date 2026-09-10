"""The address-space cap the worker puts on itself.

This runs in the child, before the sandbox engages and long before any
model-written code is loaded. It is a guard against a runaway allocation
taking the host down with it, not a security boundary; the sandbox is that.
"""

from __future__ import annotations

import resource

__all__ = ["DEFAULT_ADDRESS_SPACE", "apply_address_space_limit"]

# Ample headroom for a data frame or two and the libraries that read them. A
# smaller limit inherited from a container still wins, as it should: the host
# knows how much memory it is prepared to give away and this does not.
DEFAULT_ADDRESS_SPACE = 8 * 1024**3


def apply_address_space_limit(limit: int = DEFAULT_ADDRESS_SPACE) -> int | None:
    """Cap this process's address space, and report what stuck.

    Returns the limit in force afterwards, which is ``limit`` or whatever
    smaller limit was already inherited. Returns ``None`` where the kernel
    does not enforce ``RLIMIT_AS`` at all: recent macOS rejects the call, and
    refusing to start the worker over a missing backstop would trade a working
    sandbox for none.
    """
    soft, hard = resource.getrlimit(resource.RLIMIT_AS)
    for inherited in (soft, hard):
        if inherited != resource.RLIM_INFINITY and inherited < limit:
            limit = inherited
    try:
        resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
    except (OSError, ValueError):
        # CPython raises ValueError for the kernel's EINVAL, which is how a
        # host that has no RLIMIT_AS to set answers.
        return None
    return limit

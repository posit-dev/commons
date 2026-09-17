"""Capping the worker's address space, before model code runs.

This runs in the child, before the sandbox engages and any model-written code
is loaded. It guards against a runaway allocation taking the host down
with it; the security boundary is the sandbox.
"""

from __future__ import annotations

import errno
import resource

__all__ = ["DEFAULT_ADDRESS_SPACE", "apply_address_space_limit"]

# Ample headroom for a data frame or two and the libraries that read them. A
# smaller limit inherited from a container still wins
DEFAULT_ADDRESS_SPACE = 8 * 1024**3


def apply_address_space_limit(limit: int = DEFAULT_ADDRESS_SPACE) -> int | None:
    """Cap this process's address space, and report what stuck.

    Returns the limit in force afterwards: ``limit``, or a smaller one
    already inherited. Returns ``None`` where the kernel has no
    ``RLIMIT_AS`` to set, as on recent macOS; a missing backstop is no
    reason to refuse a working sandbox. Any other failure raises, since a
    refused call is indistinguishable from a missing limit on such a host.
    """
    soft, hard = resource.getrlimit(resource.RLIMIT_AS)
    for inherited in (soft, hard):
        if inherited != resource.RLIM_INFINITY and inherited < limit:
            limit = inherited
    try:
        resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
    except ValueError:
        # CPython raises ValueError for the kernel's EINVAL, which is how a
        # host that has no RLIMIT_AS to set answers.
        return None
    except OSError as exc:
        if exc.errno != errno.EINVAL:
            raise
        return None
    return limit

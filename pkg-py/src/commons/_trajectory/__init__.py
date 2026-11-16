"""Read conversation trajectories back from the traces that trajectory logging writes.

``pkg-r/R/trajectory-read.R`` holds the R counterparts of these functions.
"""

import math
import os

from ._build import (
    ExchangeProvenance,
    Trajectory,
    build_trajectories,
    drop_contentless,
)
from ._source import read_source_spans, resolve_trajectory_source

__all__ = ["ExchangeProvenance", "Trajectory", "trajectory_read"]

_N_MESSAGE = "n must be a whole number of at least 1, or None."


def trajectory_read(
    source: str | os.PathLike[str] | None = None,
    *,
    n: int | None = None,
) -> dict[str, Trajectory]:
    """Read the conversations an agent logged with `log=True`."""
    keep = _check_n(n)
    spans = read_source_spans(resolve_trajectory_source(source))
    trajectories = drop_contentless(build_trajectories(spans))
    if keep is not None:
        trajectories = dict(list(trajectories.items())[-keep:])
    return trajectories


def _check_n(n: object) -> int | None:
    if n is None:
        return None
    if isinstance(n, float):
        if not (math.isfinite(n) and n.is_integer()):
            raise ValueError(_N_MESSAGE)
        n = int(n)
    if isinstance(n, bool) or not isinstance(n, int):
        raise TypeError(_N_MESSAGE)
    if n < 1:
        raise ValueError(_N_MESSAGE)
    return n

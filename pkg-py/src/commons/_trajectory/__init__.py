"""Read conversation trajectories back from the traces that trajectory logging writes.

``pkg-r/R/trajectory-read.R`` holds the R counterparts of these functions.
"""

import math
import os
from datetime import date, datetime, time

from ._build import (
    Exchange,
    Trajectory,
    build_trajectories,
    drop_contentless,
    filter_chat_spans,
)
from ._source import (
    ConnectSource,
    read_source_spans,
    resolve_trajectory_source,
    warn_if_tracing_disabled,
)

__all__ = ["Exchange", "Trajectory", "trajectory_read"]

_N_MESSAGE = "n must be a whole number of at least 1, or None."
_BOUND_FORMATS = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%dT%H:%M",
    "%Y-%m-%d",
)


def trajectory_read(
    source: str | os.PathLike[str] | None = None,
    *,
    n: int | None = None,
    since: datetime | date | str | None = None,
    until: datetime | date | str | None = None,
) -> dict[str, Trajectory]:
    """Read the conversations an agent logged with `log=True`.

    `source` is where to read from. With none, this content's own traces
    are read when it runs on Posit Connect. Off Connect, the deployed
    content's traces are read when the project has a deployment record,
    written by rsconnect-python under `rsconnect-python/` or by the R
    package rsconnect under `rsconnect/`. Otherwise the directory the file
    exporter writes to is read: the directory of
    `OTEL_EXPORTER_OTLP_TRACES_FILE` when it is set, and otherwise
    `COMMONS_TRACES_DIR`, or `commons-traces` under the temporary
    directory. `source` can also be a Connect content GUID, a content URL
    (`.../content/<guid>/`), a vanity URL (`.../content/<name>/`), a
    dashboard URL (`.../connect/#/apps/<guid>/`), or a directory of OTLP
    JSON trace files: `trace.jsonl`, `trace-<n>.jsonl`, and files named
    from the `OTEL_EXPORTER_OTLP_TRACES_FILE` template.

    Reading from Connect (2026.09.0 or later) needs `CONNECT_API_KEY`, and
    `CONNECT_SERVER` when the server is not in the URL, the deployment
    record, or the one server registered with rsconnect-python. The key's
    user needs editor-level access to the content: they must own it or be
    a collaborator (see `share_with` on `Commons`). When Connect finds no
    traces, a warning names the content's or the server's tracing setting
    when it can tell that one is off.

    `since` and `until` keep the chat activity at or after `since` and
    before `until`. Each is a datetime, a date, or a string like
    "2026-07-22" or "2026-07-22 14:30:00". A date, a string, or a datetime
    without a time zone is read in local time. A conversation that continues
    past `until` is returned as it was at `until`. A conversation that
    started before `since` is returned with the history its latest call in
    the window recorded, and its exchanges take provenance only from calls
    in the window, so an exchange answered only before `since` has no
    record. `n` then keeps the `n` most recent conversations. On Connect,
    `since` and `until` are sent with the request, so Connect leaves out
    most traces outside the window. The per-job trace stores that older
    content can have are filtered by `since` only. When a chat span's
    ancestry is cut off, the read is repeated once without `since`, and the
    job stores are then read unfiltered. `n` is not sent, and is
    applied after the read.

    Conversations whose spans record no message content are dropped. The
    result is keyed by conversation id, with the oldest conversation
    first.
    """
    keep = _check_n(n)
    low = window_bound(since, "since")
    high = window_bound(until, "until")
    resolved = resolve_trajectory_source(source)
    try:
        spans = read_source_spans(resolved, n=keep, since=low, until=high)
        if isinstance(resolved, ConnectSource) and not spans:
            warn_if_tracing_disabled(resolved)
    finally:
        if isinstance(resolved, ConnectSource):
            resolved.client.close()
    spans = filter_chat_spans(spans, low, high)
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


def window_bound(value: object, arg: str) -> datetime | None:
    """A window bound as an aware datetime; a date or naive time is local time."""
    if value is None:
        return None
    if isinstance(value, datetime):
        return value if value.utcoffset() is not None else value.astimezone()
    if isinstance(value, date):
        return datetime.combine(value, time()).astimezone()
    message = (
        f"{arg} must be a datetime, a date, or a datetime string like "
        "'2026-07-22 14:30:00'."
    )
    if not isinstance(value, str):
        raise TypeError(message)
    for fmt in _BOUND_FORMATS:
        try:
            parsed = datetime.strptime(value, fmt)  # noqa: DTZ007 (local time)
        except ValueError:
            continue
        # The string must reformat to itself, so a parse cannot accept only
        # part of it.
        if parsed.strftime(fmt) == value:
            return parsed.astimezone()
    raise ValueError(message)

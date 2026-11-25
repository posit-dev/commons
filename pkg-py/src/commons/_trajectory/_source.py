"""Resolve and read the source of trajectories: a local directory or Connect content."""

import os
import re
import warnings
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import unquote

from .._connect import (
    FROM_PAD,
    ConnectClient,
    ConnectError,
    connect_content_guid,
    connect_trace_lines,
    content,
    is_connect_runtime,
    server_settings,
    vanity_guid,
)
from .._tracing import CONTENT_TRACING_HINT, SERVER_TRACING_HINT
from ._build import (
    chat_span_gives_turns,
    chat_spans_by_conversation,
    filter_chat_spans,
    has_severed_ancestry,
    is_chat_span,
    latest_chat_spans,
    reaches_first_question,
    span_index,
)
from ._deployment import GUID_PATTERN, find_deployment, registered_connect_servers
from ._otlp import (
    Span,
    local_traces_dir,
    parse_otlp_line,
    parse_otlp_lines,
    read_local_spans,
)

EMPTY_READ_MESSAGE = "No traces were found for this content."

_CONTENT_GUID = re.compile(GUID_PATTERN)
_GUID = "(" + GUID_PATTERN + ")"
_CONTENT_URL = re.compile(r"(.*?)(?:/__api__/v1)?/content/" + _GUID)
# A dashboard's path, by default /connect, is not part of the server's URL.
_DASHBOARD_URL = re.compile(r"(.*?)(?:/connect)?/#/apps/" + _GUID)
_VANITY_URL = re.compile(r"(.*?)/content/(.+?)/?$")
_URL = re.compile(r"^https?://")


@dataclass(frozen=True)
class LocalSource:
    path: Path


@dataclass(frozen=True)
class ConnectSource:
    client: ConnectClient
    guid: str


def is_content_guid(text: str) -> bool:
    return _CONTENT_GUID.fullmatch(text) is not None


def content_url_guid(url: str) -> tuple[str, str] | None:
    """The server and GUID in a content or dashboard URL."""
    if not _URL.match(url):
        return None
    # Drop the query, but keep the fragment, where a dashboard URL names the GUID.
    url = re.sub(r"\?[^#]*", "", url, count=1)
    match = _CONTENT_URL.match(url) or _DASHBOARD_URL.match(url)
    return None if match is None else (match.group(1), match.group(2))


def content_vanity_url(url: str) -> tuple[str, str] | None:
    """The server and the search query in a vanity URL."""
    if not _URL.match(url):
        return None
    match = _VANITY_URL.match(re.sub(r"[?#].*$", "", url, flags=re.DOTALL))
    return None if match is None else (match.group(1), unquote(match.group(2)))


def resolve_trajectory_source(
    source: str | os.PathLike[str] | None,
) -> LocalSource | ConnectSource:
    """The local directory or the Connect content that `source` names."""
    if source is None:
        return _default_source()
    if isinstance(source, str):
        # A GUID or URL names Connect content, never a local directory.
        if is_content_guid(source):
            return ConnectSource(ConnectClient.from_env(server=guid_server()), source)
        if _URL.match(source):
            return _url_source(source)
        return LocalSource(_directory(source))
    if isinstance(source, os.PathLike):
        path = os.fspath(source)
        if isinstance(path, str):
            return LocalSource(_directory(path))
    raise TypeError(
        "source must be None, a directory path, a Connect content GUID, or a "
        "Connect content URL."
    )


def _default_source() -> LocalSource | ConnectSource:
    if is_connect_runtime():
        return ConnectSource(ConnectClient.from_env(), connect_content_guid())
    # Point a warning at the caller of trajectory_read().
    deployment = find_deployment(stacklevel=5)
    if deployment is not None:
        client = ConnectClient.from_env(server=deployment.server)
        return ConnectSource(client, deployment.guid)
    return LocalSource(local_traces_dir())


def _url_source(url: str) -> ConnectSource:
    parsed = content_url_guid(url)
    if parsed is not None:
        server, guid = parsed
        return ConnectSource(ConnectClient.from_env(server=server), guid)
    vanity = content_vanity_url(url)
    if vanity is None:
        raise ValueError(
            f"Can't identify Connect content from {url}. Supported URLs contain "
            "/content/<guid>, /content/<name>, or #/apps/<guid>."
        )
    server, query = vanity
    client = ConnectClient.from_env(server=server)
    try:
        return ConnectSource(client, vanity_guid(client, url, query))
    except BaseException:
        client.close()
        raise


def guid_server() -> str:
    """The server for a GUID source.

    CONNECT_SERVER, then the project's deployment record, then the one server
    registered with rsconnect-python.
    """
    server = os.environ.get("CONNECT_SERVER", "")
    if server:
        return server
    # The GUID names the content, so which record is read needs no warning.
    deployment = find_deployment(quiet=True)
    if deployment is not None:
        return deployment.server
    servers = registered_connect_servers()
    if len(servers) == 1:
        return servers[0]
    message = (
        "Can't determine which Posit Connect server contains this GUID. "
        "Set CONNECT_SERVER or pass a full content URL."
    )
    if len(servers) > 1:
        message += f" Registered Connect servers: {', '.join(servers)}."
    raise ValueError(message)


def _directory(path: str) -> Path:
    # Path("") is the working directory, but an empty value names no directory.
    return Path(path) if path else Path(os.devnull)


def read_source_spans(
    source: LocalSource | ConnectSource,
    *,
    n: int | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
) -> list[Span]:
    """The source's spans; `n`, `since`, and `until` narrow a read from Connect."""
    if isinstance(source, ConnectSource):
        return read_connect_spans(
            source.client, source.guid, n=n, since=since, until=until
        )
    return read_local_spans(source.path)


def read_connect_spans(
    client: ConnectClient,
    guid: str,
    *,
    n: int | None,
    since: datetime | None,
    until: datetime | None,
) -> list[Span]:
    """The content's spans, with the window sent to Connect.

    With `n`, the read stops once it holds the `n` latest conversations whole.
    """
    spans = _fetch_connect_spans(client, guid, since, n=n, since=since, until=until)
    # The padded `from` can still drop a turn span that started more than an
    # hour earlier, so a severed chain is fetched once more without it.
    if since is not None and has_severed_ancestry(
        filter_chat_spans(spans, since, until)
    ):
        spans = _fetch_connect_spans(client, guid, None, n=n, since=since, until=until)
    return spans


def _fetch_connect_spans(
    client: ConnectClient,
    guid: str,
    pushdown: datetime | None,
    *,
    n: int | None,
    since: datetime | None,
    until: datetime | None,
) -> list[Span]:
    enough = None if n is None else enough_trace_lines(n, since, until)
    lines = connect_trace_lines(
        client, guid, since=pushdown, until=until, enough=enough
    )
    return parse_otlp_lines(lines)


def enough_trace_lines(
    n: int, since: datetime | None, until: datetime | None
) -> Callable[[Sequence[str]], bool]:
    """A check that the lines read so far hold the `n` latest conversations whole.

    A conversation is whole once the lines reach its first question. Connect
    sorts lines newest first by the start time of each line's first span, and
    one line can hold spans of several conversations, so a line not yet read
    can still hold a later chat span. The check also waits for a line that
    sorts an hour (`FROM_PAD`) before the conversations' earliest chat span.
    That assumes a span lasts at most an hour, as the `from` pushdown does.
    """
    spans: list[Span] = []
    parsed = 0
    oldest: int | None = None
    pad = -FROM_PAD // timedelta(microseconds=1) * 1000
    # Settled once the ancestry is intact, so each span is checked once.
    gives_turns: dict[tuple[str, str], bool] = {}

    def enough(lines: Sequence[str]) -> bool:
        nonlocal parsed, oldest
        for line in lines[parsed:]:
            line_spans, sort_time = parse_otlp_line(line)
            spans.extend(line_spans)
            if sort_time is not None and (oldest is None or sort_time < oldest):
                oldest = sort_time
        parsed = len(lines)
        kept = filter_chat_spans(spans, since, until)
        if has_severed_ancestry(kept):
            return False
        chat_spans = [span for span in kept if is_chat_span(span)]
        index = span_index(kept)
        latest = []
        for id_, span in latest_chat_spans(chat_spans).items():
            key = (span.trace_id, span.span_id)
            if key not in gives_turns:
                gives_turns[key] = chat_span_gives_turns(span, index)
            if gives_turns[key]:
                latest.append(id_)
        if len(latest) < n:
            return False
        by_conversation = chat_spans_by_conversation(chat_spans)
        recent = [by_conversation[id_] for id_ in latest[-n:]]
        if not all(reaches_first_question(spans_) for spans_ in recent):
            return False
        first = min(span.start_time_unix_nano for spans_ in recent for span in spans_)
        return oldest is not None and oldest + pad <= first

    return enough


def warn_if_tracing_disabled(source: ConnectSource) -> None:
    """Warn when a setting explains why Connect has no traces for the content.

    Called from trajectory_read(), so the warning points at its caller.
    """
    try:
        content_enabled = content(source.client, source.guid).get("otel_enabled")
    except (ConnectError, ValueError):
        content_enabled = None
    try:
        settings = server_settings(source.client)
    except (ConnectError, ValueError):
        settings = {}
    hints = []
    if content_enabled is False:
        hints.append(CONTENT_TRACING_HINT)
    if settings.get("allow_content_instrumentation") is False:
        hints.append(SERVER_TRACING_HINT)
    if hints:
        warnings.warn(" ".join([EMPTY_READ_MESSAGE, *hints]), stacklevel=3)

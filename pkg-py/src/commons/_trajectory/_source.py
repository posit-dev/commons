"""Resolve and read the source of trajectories: a local directory or Connect content."""

import os
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote

from .._connect import (
    ConnectClient,
    connect_content_guid,
    connect_trace_lines,
    is_connect_runtime,
    vanity_guid,
)
from ._deployment import find_deployment, registered_connect_servers
from ._otlp import Span, local_traces_dir, parse_otlp_lines, read_local_spans

_CONTENT_GUID = re.compile(r"[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
_GUID = r"([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})"
_CONTENT_URL = re.compile(r"(.*?)/content/" + _GUID)
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
    deployment = find_deployment()
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
    deployment = find_deployment()
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


def read_source_spans(source: LocalSource | ConnectSource) -> list[Span]:
    if isinstance(source, ConnectSource):
        return parse_otlp_lines(connect_trace_lines(source.client, source.guid))
    return read_local_spans(source.path)

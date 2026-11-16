"""Resolve where trajectories are read from; only local directories are read for now."""

import os
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote

from .._connect import is_connect_runtime
from ._otlp import Span, local_traces_dir, read_local_spans

CONNECT_NOT_SUPPORTED = (
    "Reading trajectories from Posit Connect is not supported yet. "
    "Pass a directory of trace files."
)

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


def resolve_trajectory_source(source: str | os.PathLike[str] | None) -> LocalSource:
    """The directory to read; a Connect source raises NotImplementedError."""
    if source is None:
        if is_connect_runtime():
            raise NotImplementedError(CONNECT_NOT_SUPPORTED)
        return LocalSource(local_traces_dir())
    if isinstance(source, str):
        # A GUID or URL names Connect content, never a local directory.
        if is_content_guid(source) or source.startswith(("http://", "https://")):
            raise NotImplementedError(CONNECT_NOT_SUPPORTED)
        return LocalSource(_directory(source))
    if isinstance(source, os.PathLike):
        path = os.fspath(source)
        if isinstance(path, str):
            return LocalSource(_directory(path))
    raise TypeError(
        "source must be None, a directory path, a Connect content GUID, or a "
        "Connect content URL."
    )


def _directory(path: str) -> Path:
    # Path("") is the working directory, but an empty value names no directory.
    return Path(path) if path else Path(os.devnull)


def read_source_spans(source: LocalSource) -> list[Span]:
    return read_local_spans(source.path)

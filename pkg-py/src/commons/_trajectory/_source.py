"""Resolve where trajectories are read from; only local directories are read for now."""

import os
import re
from dataclasses import dataclass
from pathlib import Path

from .._connect import is_connect_runtime
from ._otlp import Span, local_traces_dir, read_local_spans

CONNECT_NOT_SUPPORTED = (
    "Reading trajectories from Posit Connect is not supported yet. "
    "Pass a directory of trace files."
)

_CONTENT_GUID = re.compile(r"[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")


@dataclass(frozen=True)
class LocalSource:
    path: Path


def is_content_guid(text: str) -> bool:
    return _CONTENT_GUID.fullmatch(text) is not None


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
        # Path("") is the working directory, but an empty value names no directory.
        return LocalSource(Path(source) if source else Path(os.devnull))
    if isinstance(source, os.PathLike):
        path = os.fspath(source)
        if isinstance(path, str):
            return LocalSource(Path(path))
    raise TypeError(
        "source must be None, a directory path, a Connect content GUID, or a "
        "Connect content URL."
    )


def read_source_spans(source: LocalSource) -> list[Span]:
    return read_local_spans(source.path)

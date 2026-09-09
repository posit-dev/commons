"""Where the browser serves the icons the asides reference.

The asides are rendered mid-stream by ``_citations.py`` and ``_provenance.py``,
neither of which may import shiny, so an icon URL has to be resolvable at scan
time rather than patched into finished HTML. The UI layer records the URL its
asset bundle is served under and the asides resolve against it. With no bundle
recorded, no icon is emitted. ``pkg-r/R/citations.R`` reads the dependency
directly, which it can because R's asides and its UI ship in one package.
"""

from __future__ import annotations

import importlib.resources
from pathlib import Path

__all__ = ["get_asset_base_url", "icon_url", "set_asset_base_url"]

_FIGS_SUBDIR = "www/commons-chat/figs"

_asset_base_url: str | None = None


def set_asset_base_url(base: str | None) -> None:
    """Record the URL the asset bundle is served under, or None for no bundle.

    Process-wide, which costs nothing across concurrent sessions: the URL
    carries the installed package's version and its assets' newest mtime, so
    every session in one process derives the same string.
    """
    global _asset_base_url
    _asset_base_url = base


def get_asset_base_url() -> str | None:
    """The URL the asset bundle is served under, or None when none is."""
    return _asset_base_url


def icon_url(file: str | None) -> str | None:
    """The served URL of one icon in ``figs/``.

    None when no bundle is being served, when the caller names no icon, or
    when the bundle does not ship the file, since a URL nothing backs renders
    as a broken image rather than as no icon at all.
    """
    if file is None or _asset_base_url is None or not _figs_path(file).is_file():
        return None
    return f"{_asset_base_url}/figs/{file}"


def _figs_path(file: str) -> Path:
    return Path(str(importlib.resources.files("commons"))) / _FIGS_SUBDIR / file

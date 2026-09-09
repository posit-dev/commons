"""The browser assets commons ships, as a dependency a page can serve."""

from __future__ import annotations

import importlib.resources
from importlib.metadata import version as distribution_version
from pathlib import Path

from htmltools import HTMLDependency
from packaging.version import Version

from .._icons import set_asset_base_url

__all__ = ["asset_base_url", "commons_chat_dependency"]

_SUBDIR = "www/commons-chat"


def _asset_dir() -> Path:
    return Path(str(importlib.resources.files("commons"))) / _SUBDIR


def _asset_version() -> str:
    """Asset version used for caching so browsers invalidate when assets are updated."""
    stamp = max(p.stat().st_mtime_ns for p in _asset_dir().rglob("*") if p.is_file())
    base = Version(distribution_version("commons")).base_version
    return f"{base}.{stamp}"


def commons_chat_dependency() -> HTMLDependency:
    """The dependency serving the chat script, stylesheet and icons."""
    dep = HTMLDependency(
        name="commons-chat",
        version=_asset_version(),
        source={"package": "commons", "subdir": _SUBDIR},
        script={"src": "commons-chat.js"},
        stylesheet={"href": "commons-chat.css"},
        all_files=True,
    )
    # The asides build icon URLs as they stream and cannot import shiny, so
    # this is where they learn where the icons are. Told on every build rather
    # than once, because the version carries an asset mtime.
    set_asset_base_url(_base_url(dep))
    return dep


def asset_base_url() -> str:
    """The URL the assets are served under on a page.

    Includes the library prefix htmltools renders a dependency's own hrefs
    under, so the result is a URL that resolves rather than the name of the
    directory holding the assets.
    """
    return _base_url(commons_chat_dependency())


def _base_url(dep: HTMLDependency) -> str:
    return dep.source_path_map()["href"]

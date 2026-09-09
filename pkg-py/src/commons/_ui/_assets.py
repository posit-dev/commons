"""The browser assets commons ships, as a dependency a page can serve."""

from __future__ import annotations

import importlib.resources
from importlib.metadata import version as distribution_version
from pathlib import Path

from htmltools import HTMLDependency
from packaging.version import Version

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
    return HTMLDependency(
        name="commons-chat",
        version=_asset_version(),
        source={"package": "commons", "subdir": _SUBDIR},
        script={"src": "commons-chat.js"},
        stylesheet={"href": "commons-chat.css"},
        all_files=True,
    )


def asset_base_url() -> str:
    """The directory the assets are served under, relative to the library."""
    dep = commons_chat_dependency()
    return f"{dep.name}-{dep.version}"

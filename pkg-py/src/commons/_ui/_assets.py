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
    """A cache key, not a distribution version.

    Folding the newest asset mtime into the version is what makes a browser
    refetch an edited asset. htmltools puts the string straight into the
    served path, so a PEP 440 local version and its `+` are ruled out; the
    package's release segments and the stamp are both path-safe.
    """
    stamp = max(p.stat().st_mtime for p in _asset_dir().rglob("*") if p.is_file())
    base = Version(distribution_version("commons")).base_version
    return f"{base}.{int(stamp)}"


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

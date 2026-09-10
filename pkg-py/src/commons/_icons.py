"""Where the browser serves the icons referenced by the asides.

``_citations.py`` and ``_provenance.py`` build asides as finished HTML
strings while the model's response streams, with no post-processing pass,
so an icon URL must be complete the moment an aside is written. In the Python
package, they are core modules while shiny is an optional extra, so it is not
guaranteed they would be able to ask the UI layer where its assets are served;
the UI layer instead records the served URL through this module's
``set_asset_base_url()`` when it builds the ``HTMLDependency`` carrying
the assets. If no URL is recorded, no icon is emitted. This differs from the
R implementation, which ships the commons core, asides, and UI in one package, so
``pkg-r/R/citations.R`` reads the dependency directly.
"""

from __future__ import annotations

import importlib.resources
from pathlib import Path

__all__ = ["get_asset_base_url", "icon_url", "set_asset_base_url"]

_FIGS_SUBDIR = "www/commons-chat/figs"

_asset_base_url: str | None = None


def set_asset_base_url(base: str | None) -> None:
    """Record the URL the asset bundle is served under, or None for no bundle.

    Process-wide, which is safe across concurrent sessions: the URL
    carries the package version and the assets' newest mtime, so every
    session in a process derives the same string.
    """
    global _asset_base_url
    _asset_base_url = base


def get_asset_base_url() -> str | None:
    """The URL the asset bundle is served under, or None when none is."""
    return _asset_base_url


def icon_url(file: str | None) -> str | None:
    """The served URL of one icon in ``figs/``.

    None when no bundle is served, when ``file`` is None, or when the
    bundle does not ship the file: an unbacked URL renders as a broken
    image rather than no icon.
    """
    if file is None or _asset_base_url is None or not _figs_path(file).is_file():
        return None
    return f"{_asset_base_url}/figs/{file}"


def _figs_path(file: str) -> Path:
    return Path(str(importlib.resources.files("commons"))) / _FIGS_SUBDIR / file

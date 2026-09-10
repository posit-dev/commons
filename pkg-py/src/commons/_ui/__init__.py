"""The chat surface: what a py-shiny app needs to drive an agent."""

from __future__ import annotations

import importlib.util

# What `commons[shiny]` installs, and what this package imports of it.
_EXTRA_PACKAGES = ("packaging", "shiny", "shinychat")


def _missing_packages() -> list[str]:
    missing: list[str] = []
    for name in _EXTRA_PACKAGES:
        try:
            found = importlib.util.find_spec(name) is not None
        except ImportError:
            found = False
        if not found:
            missing.append(name)
    return missing


def _listed(names: list[str]) -> str:
    if len(names) == 1:
        return names[0]
    return " and ".join([", ".join(names[:-1]), names[-1]])


try:
    from ._assets import asset_base_url, commons_chat_dependency
    from ._server import server
    from ._theme import theme
except ModuleNotFoundError as err:
    # Name every missing package, as `check_chat_packages()` does in
    # pkg-r/R/chat.R, so one install fixes the import.
    names = _missing_packages() or [err.name or "a package"]
    raise ImportError(
        f"commons.ui needs {_listed(names)}, which "
        f"{'is' if len(names) == 1 else 'are'} not installed. "
        'Install with: pip install "commons[shiny]"'
    ) from err

__all__ = ["asset_base_url", "commons_chat_dependency", "server", "theme"]

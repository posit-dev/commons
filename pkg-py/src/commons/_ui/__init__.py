"""The chat surface: what a py-shiny app needs to drive an agent."""

from __future__ import annotations

import importlib.util
from collections.abc import Sequence

_EXTRA_PACKAGES = ("htmltools", "shiny", "shinychat")


def _missing_extra_packages(
    packages: Sequence[str] = _EXTRA_PACKAGES,
) -> list[str]:
    return [name for name in packages if importlib.util.find_spec(name) is None]


def _require_extra(missing: Sequence[str] | None = None) -> None:
    missing = _missing_extra_packages() if missing is None else missing
    if not missing:
        return
    names = ", ".join(missing)
    verb = "is" if len(missing) == 1 else "are"
    raise ImportError(
        f"commons.ui needs {names}, which {verb} not installed. "
        'Install them with: pip install "commons[shiny]"'
    )


_require_extra()

from ._assets import asset_base_url, commons_chat_dependency

__all__ = ["asset_base_url", "commons_chat_dependency"]

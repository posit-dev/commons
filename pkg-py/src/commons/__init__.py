"""Build trustworthy data agents.

Give an LLM data, semantic, and context layers to work with, tools for
querying them, and A/B/C provenance semantics so every answer carries a
classification as to how much it can be trusted.
"""

from typing import Any

from ._agent import Commons
from ._context_layer import ContextLayer, context_layer
from ._data_source import DataSource, data_source, list_tables
from ._measures import Injected, Measure, SemanticLayer, measure, semantic_layer
from ._provenance import Tag

__all__: list[str] = [
    "Commons",
    "ContextLayer",
    "DataSource",
    "Injected",
    "Measure",
    "SemanticLayer",
    "Tag",
    "context_layer",
    "data_source",
    "list_tables",
    "measure",
    "semantic_layer",
]


def __getattr__(name: str) -> Any:
    # `commons.ui` is resolved on first use so that importing commons does
    # not import shiny for the many users who never build a UI.
    if name == "ui":
        from . import _ui

        return _ui
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


def __dir__() -> list[str]:
    return sorted([*__all__, "ui"])

"""Build trustworthy data agents.

Give an LLM data, semantic, and context layers to work with, tools for
querying them, and A/B/C provenance semantics so every answer carries a
classification as to how much it can be trusted.
"""

from ._data_source import DataSource, data_source, list_tables

__all__: list[str] = ["DataSource", "data_source", "list_tables"]

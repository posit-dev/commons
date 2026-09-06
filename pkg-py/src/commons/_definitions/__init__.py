"""Governed definitions: the registry, and the compiler that feeds it.

Definitions are authored in data-dict's expression language, not in the SQL
dialect of the attached source, so they are type-checked against the
dictionary and lowered to the source's dialect before anything runs. That work
sits behind one export-record seam, pinned to data-dict commit
d950c5ac90d0ab939d330600f3a5ee1bfde0f604, so it can be replaced by a shared
data-dict interface later.

Runtime code consumes `ExportRecord` and never an expression parser or a typed
IR. Cross-implementation conformance against the data-dict binary is the
authority, not this code.
"""

from ._compile import attach_compiled_definitions, mixed_grain
from ._registry import (
    ExportRecord,
    Registry,
    applied_text,
    build_registry,
    context_chunks,
    entry_text,
    expand_tokens,
    index_overflows,
    index_text,
)

__all__ = [
    "ExportRecord",
    "Registry",
    "applied_text",
    "attach_compiled_definitions",
    "build_registry",
    "context_chunks",
    "entry_text",
    "expand_tokens",
    "index_overflows",
    "index_text",
    "mixed_grain",
]

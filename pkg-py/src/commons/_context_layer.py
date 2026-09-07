"""A context layer: text an agent retrieves from to interpret its data source.

Context is retrieved when relevant. Facts needed in every conversation belong
in the agent's instructions, not here. ``pkg-r/R/context-layer.R`` implements
the same behaviour for R, and ``tests/shared/context_layer.json`` pins the
parts that must agree.
"""

from __future__ import annotations

import os
import re
from collections.abc import Iterable

__all__ = ["ContextLayer", "context_layer"]

# Frontmatter carries file metadata (e.g. provenance) meant for maintainers,
# not the model; drop it so retrieval can't surface it. Anchored to the start
# so a '---' thematic break in the body survives. The metadata block is
# optional so an emptied-out fence is removed rather than indexed as text.
_FRONTMATTER = re.compile(r"\A---\r?\n(.*?\r?\n)?---(\r?\n|\Z)", re.DOTALL)


def strip_frontmatter(md: str) -> str:
    return _FRONTMATTER.sub("", md, count=1)


class ContextLayer:
    """Text that helps an agent interpret its data source.

    Construct one with :func:`context_layer`. Internals are private and may
    change without notice.
    """

    def __init__(self, docs: Iterable[str] = ()) -> None:
        self._docs = tuple(docs)

    @property
    def docs(self) -> tuple[str, ...]:
        """The documents as read from their files, frontmatter stripped."""
        return self._docs

    def __repr__(self) -> str:
        n = len(self._docs)
        return f"<ContextLayer: {n} document{'' if n == 1 else 's'}>"


def context_layer(
    files: Iterable[str | os.PathLike[str]] = (),
) -> ContextLayer:
    """Create a context layer from text or Markdown files.

    ``files`` must be a collection of paths; a bare string or path raises
    ``TypeError``. Files are read eagerly and decoded as UTF-8, so a missing
    path (``FileNotFoundError``), a directory (``IsADirectoryError``), or a
    file in another encoding (``UnicodeDecodeError``) fails here rather than
    mid-conversation.
    """
    if isinstance(files, (str, bytes, os.PathLike)):
        raise TypeError(
            f"`files` must be a collection of paths, not {type(files).__name__}. "
            f"Pass a list: files=[{files!r}]."
        )

    # Read eagerly so a bad path fails at construction; index lazily (see
    # ContextLayer.search).
    docs: list[str] = []
    for path in files:
        with open(path, encoding="utf-8") as handle:
            md = strip_frontmatter(handle.read())
        # readLines() in pkg-r/R/context-layer.R drops the final line ending;
        # do the same so both read the same document from the same file.
        md = md.removesuffix("\n")
        if md.strip():
            docs.append(md)

    return ContextLayer(docs)

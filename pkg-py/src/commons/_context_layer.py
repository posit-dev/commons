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

from raghilda.chunker import MarkdownChunker
from raghilda.document import MarkdownDocument
from raghilda.store import DuckDBStore

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
        self._store_cache: DuckDBStore | None = None

    @property
    def docs(self) -> tuple[str, ...]:
        """The documents as read from their files, frontmatter stripped."""
        return self._docs

    def __repr__(self) -> str:
        n = len(self._docs)
        return f"<ContextLayer: {n} document{'' if n == 1 else 's'}>"

    # Store setup (duckdb creation, chunk insertion, BM25 indexing) is the
    # most expensive part of building an agent and many conversations never
    # search, so it is deferred to the first search.
    def _store(self) -> DuckDBStore:
        if self._store_cache is None:
            store = DuckDBStore.create(location=":memory:", embed=None)
            chunker = MarkdownChunker()
            # ingest() upserts on origin and rejects an empty one, so each
            # document gets a distinct synthetic origin. Two files with
            # identical text would otherwise collapse into one chunk.
            store.ingest(
                [
                    MarkdownDocument(content=doc, origin=f"commons-context-{i}")
                    for i, doc in enumerate(self._docs)
                ],
                prepare=chunker.chunk,
            )
            store.build_index(type="bm25")
            self._store_cache = store
        return self._store_cache

    def search(self, query: str, top_k: int = 3) -> list[str]:
        """Retrieve the chunks most relevant to ``query``."""
        if not self._docs:
            return []
        hits = self._store().retrieve_bm25(query, top_k=top_k)
        # retrieve_bm25 pads its result up to top_k with unscored rows, so a
        # query that matches nothing still comes back full. Only scored rows
        # are hits.
        return [
            hit.text.strip()
            for hit in hits
            if any(m.name == "bm25" and m.value is not None for m in hit.metrics)
        ]


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

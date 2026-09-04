"""A context layer: text an agent retrieves from to interpret its data source.

Context is retrieved when relevant. Facts needed in every conversation belong
in the agent's instructions, not here. ``pkg-r/R/context-layer.R`` implements
the same behaviour for R, and ``tests/shared/context_layer.json`` pins the
parts that must agree.
"""

from __future__ import annotations

import os
import re
import threading
from collections.abc import Iterable
from typing import TYPE_CHECKING

from raghilda.chunker import MarkdownChunker
from raghilda.document import MarkdownDocument
from raghilda.store import DuckDBStore

if TYPE_CHECKING:
    from ._data_dictionary import DataDictionary
    from ._data_source import DataSource

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
        self._store_lock = threading.Lock()

    @property
    def docs(self) -> tuple[str, ...]:
        """The documents as read from their files, frontmatter stripped."""
        return self._docs

    def __repr__(self) -> str:
        n = len(self._docs)
        return f"<ContextLayer: {n} document{'' if n == 1 else 's'}>"

    # Store setup (duckdb creation, chunk insertion, BM25 indexing) is the
    # most expensive part of building an agent and many conversations never
    # search, so it is deferred to the first search. The lock keeps
    # concurrent first searches on a shared layer from each building a
    # store and discarding all but one.
    def _store(self) -> DuckDBStore:
        with self._store_lock:
            if self._store_cache is None:
                # TODO: emit the commons_context_store_build span the R
                # store build emits, once pkg-py has its tracing module.
                store = DuckDBStore.create(location=":memory:", embed=None)
                chunker = MarkdownChunker()
                # ingest() requires each document's origin to be distinct
                # and non-empty, so each gets a distinct synthetic origin.
                store.ingest(
                    [
                        MarkdownDocument(
                            content=doc, origin=f"commons-context-{i}"
                        )
                        for i, doc in enumerate(self._docs)
                    ],
                    prepare=chunker.chunk,
                )
                store.build_index(type="bm25")
                self._store_cache = store
        return self._store_cache

    def prewarm(self) -> None:
        """Build the index now so the first search does not pay for it.

        Optional and idempotent; worth calling when a search is known to be
        coming, so its cost does not land on the first user turn.
        """
        if self._docs:
            self._store()

    # Public ahead of the R counterpart: context_search() in
    # pkg-r/R/context-layer.R is internal there and spells the limit `n`.
    def search(self, query: str, top_k: int = 3) -> list[str]:
        """Retrieve the chunks most relevant to ``query``.

        Returns chunk texts, best match first, at most ``top_k`` of them.
        An empty layer, or a query nothing matches, returns an empty list.
        ``top_k`` must be at least 1.
        """
        if top_k < 1:
            raise ValueError(f"top_k must be at least 1, not {top_k}.")
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


def _dictionary_chunks(dictionary: DataDictionary | None) -> list[str]:
    """The dictionary's retrievable prose, or nothing when there is none.

    A source without a dictionary is ordinary, so the absence is handled
    here rather than by every caller.
    """
    if dictionary is None:
        return []
    return dictionary.context_chunks()


def augment_context_layer(
    layer: ContextLayer | None, sources: Iterable[DataSource]
) -> ContextLayer | None:
    """Fold each source's prose into a layer the agent can retrieve from.

    Returns a new layer, leaving the caller's untouched: source enrichment
    belongs to the agent that owns the sources, so mutating the argument
    would leak one agent's sources into the next agent built from the same
    layer. With nothing to add, the argument comes back as it went in,
    ``None`` included, so an agent with neither context nor a dictionary
    has no layer rather than an empty one.
    """
    chunks: list[str] = []
    for source in sources:
        chunks.extend(_dictionary_chunks(source.dictionary))
        # A warehouse's own semantic models contribute their retrieval prose
        # here too, as they do in pkg-r/R/context-layer.R. This package has
        # no semantic-model surface yet, so there is nothing to fold in.

    if not chunks:
        return layer

    existing = layer.docs if layer is not None else ()
    return ContextLayer([*existing, *chunks])


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

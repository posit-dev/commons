"""Keep saved chat UI on the same verified projection as live answers."""

from __future__ import annotations

import builtins
from copy import copy
from typing import Any

from chatlas import Turn
from chatlas.types import ContentText
from shinychat._history import (
    _strip_attachment_content,
    derive_node_ui,
    derive_stored_ui_message,
)
from shinychat._history_store import resolve_store
from shinychat.types import (
    ConversationMeta,
    ConversationPartition,
    ConversationRecord,
    ConversationStore,
    HistoryOptions,
)

from .._agent import Commons
from .._citation_scan import CitationScanner
from .._citations import CorpusEntry
from .._provenance import (
    collect_appended_tags,
    derive_provenance_tag,
    provenance_aside,
)
from .._reminders import BREVITY_TURN_REMINDER, RESTORED_CONVERSATION_REMINDER

_REMINDERS = {BREVITY_TURN_REMINDER, RESTORED_CONVERSATION_REMINDER}


def history_options(
    history: bool | HistoryOptions, client: Commons
) -> bool | HistoryOptions:
    if history is False:
        return False
    options = copy(history) if isinstance(history, HistoryOptions) else HistoryOptions()
    options.store = _HistoryStore(resolve_store(options.store), client)
    return options


def _project_turn(turn: Turn, scanner: CitationScanner) -> Turn:
    contents = []
    for index, content in enumerate(turn.contents):
        if turn.role == "assistant" and isinstance(content, ContentText):
            text = scanner.feed(content.text)
            if not text:
                continue
            content = content.model_copy(update={"text": text})
        elif (
            turn.role == "user"
            and index > 0
            and isinstance(content, ContentText)
            and content.text in _REMINDERS
        ):
            continue
        contents.append(content)
    return turn.model_copy(update={"contents": contents})


def _project_node(
    turns: list[dict[str, Any]], corpus: list[CorpusEntry]
) -> dict[str, Any] | None:
    raw = [Turn.model_validate(turn) for turn in turns]
    # With no turn-derived message, every cached message is out-of-band UI.
    if derive_stored_ui_message(turns) is None:  # type: ignore[arg-type]
        return None
    scanner = CitationScanner(corpus)
    projected = [_project_turn(turn, scanner) for turn in raw]
    tail = scanner.finish()
    tag = derive_provenance_tag(collect_appended_tags(raw, 0), scanner.any_verified)
    suffix = tail + provenance_aside(tag)
    if suffix and projected and projected[-1].role == "assistant":
        projected[-1].contents.append(ContentText(text=suffix))
    group = [turn.model_dump(mode="json") for turn in projected]
    # shinychat's default history derives UI from raw turns, bypassing the
    # live stream's verification. Only the render cache gets this projection.
    return derive_node_ui(group)[0]  # type: ignore[arg-type]


class _HistoryStore(ConversationStore):
    def __init__(self, store: ConversationStore, client: Commons) -> None:
        self._store = store
        self._client = client

    def _project(
        self, record: ConversationRecord, *, drop_invalid_turns: bool = False
    ) -> None:
        corpus = self._client.citation_corpus()
        for node in record.nodes.values():
            try:
                message = _project_node(node.turns, corpus)
            except (KeyError, TypeError, ValueError):
                # A broken turn invalidates the whole cached UI for this node.
                node.ui = []
                # Restore revalidates path turns, so omit the entire exchange.
                if drop_invalid_turns:
                    node.turns = []
                continue
            if message is None:
                continue
            previous = node.ui or []
            if previous and previous[0].get("attachments"):
                message["attachments"] = previous[0]["attachments"]
                message = dict(
                    _strip_attachment_content(message)  # type: ignore[arg-type]
                )
            node.ui = [message, *previous[1:]]

    async def list(self, partition: ConversationPartition) -> list[ConversationMeta]:
        return await self._store.list(partition)

    async def get(
        self, partition: ConversationPartition, conv_id: str
    ) -> ConversationRecord | None:
        record = await self._store.get(partition, conv_id)
        if record is not None:
            record = record.model_copy(deep=True)
            self._project(record, drop_invalid_turns=True)
        return record

    async def put(
        self, partition: ConversationPartition, record: ConversationRecord
    ) -> None:
        record = record.model_copy(deep=True)
        self._project(record)
        await self._store.put(partition, record)

    async def delete(self, partition: ConversationPartition, conv_id: str) -> None:
        await self._store.delete(partition, conv_id)

    async def search(
        self, partition: ConversationPartition, query: str
    ) -> builtins.list[ConversationMeta]:
        return await self._store.search(partition, query)

    async def total_size(self, partition: ConversationPartition) -> int:
        return await self._store.total_size(partition)

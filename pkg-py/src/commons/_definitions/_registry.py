"""The registry surface commons owns, whatever data-dict eventually provides.

Everything here consumes export records. Nothing here may reach into an
expression parser or a typed IR: that rule is what keeps the seam real, and
what makes an eventual swap to a shared data-dict interface a deletion rather
than a rewrite.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field, replace
from typing import Any

__all__ = [
    "ExportRecord",
    "Registry",
    "applied_text",
    "build_registry",
    "context_chunks",
    "entry_text",
    "expand_tokens",
    "index_overflows",
    "index_text",
]

INDEX_CAP_CHARS = 4000

_TOKEN = re.compile(r"\{\{\s*([^{}]+?)\s*\}\}")
_LEGACY_DOTTED = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$")
_GROUPS = {"filter": "filters", "derived": "derived", "metric": "metrics"}


@dataclass(frozen=True)
class ExportRecord:
    """One governed definition, compiled for a source and ready to expand.

    `mixed_grain` is the one field data-dict's export does not carry. It is
    derived from the typed IR, and `call_metrics` needs it to refuse a mix of
    row and aggregate definitions in one call.
    """

    name: str
    table: str
    source: str
    kind: str
    type: str | None
    expression: str
    label: str | None
    description: str | None
    details: str | None
    columns: list[str]
    definitions: list[str]
    sql: str
    target: str
    notes: list[str]
    mixed_grain: bool


@dataclass
class Registry:
    """Every source's definitions in one place."""

    records: list[ExportRecord] = field(default_factory=list)

    def for_source(self, name: str | None = None) -> list[ExportRecord]:
        if name is None:
            return list(self.records)
        return [record for record in self.records if record.source == name]


def build_registry(sources: dict[str, Any]) -> Registry:
    """Collect every source's compiled definitions into one registry.

    Takes `DataSource` values, typed loosely because `_data_source` imports
    this module and the reverse import would close the cycle.

    A definition on a table the source does not expose is a construction
    error: its token would resolve at conversation time against nothing.
    """
    records: list[ExportRecord] = []
    for label, source in sources.items():
        dictionary = getattr(source, "dictionary", None)
        if dictionary is None:
            continue
        exposed = set(getattr(source, "tables", []))
        for table, entry in dictionary.tables.items():
            compiled = getattr(entry, "compiled_definitions", None) or []
            if not compiled:
                continue
            if table not in exposed:
                raise ValueError(
                    f"The data dictionary declares definitions on table {table!r}, "
                    "which the data source does not expose. Exposed tables: "
                    f"{', '.join(sorted(exposed))}."
                )
            for record in compiled:
                records.append(replace(record, table=table, source=label))
    return Registry(records)


# ---- token expansion -----------------------------------------------------


def expand_tokens(
    sql: str, records: list[ExportRecord]
) -> tuple[str, list[ExportRecord]]:
    """Replace `{{name}}` and `{{table::name}}` with compiled SQL.

    Runs before the read-only guard, so the guard sees the SQL that will
    actually execute. Failures are tool errors the model can recover from
    in-conversation, so they name the alternatives.
    """
    tokens: list[str] = []
    for match in _TOKEN.finditer(sql):
        token = match.group(1)
        if token not in tokens:
            tokens.append(token)

    # Every token resolves against the query as written. Compiled SQL can
    # name a table the query does not, and resolving against already-expanded
    # text would let that count as the table being present, which is the check
    # that keeps a token bound to its own table.
    resolved = [(token, _resolve_token(token, sql, records)) for token in tokens]

    applied: list[ExportRecord] = []
    for token, record in resolved:
        pattern = re.compile(r"\{\{\s*" + re.escape(token) + r"\s*\}\}")
        # A lambda, not a replacement string: the SQL is literal and a
        # backslash in it would otherwise be read as an escape.
        sql = pattern.sub(lambda _match, found=record: f"({found.sql})", sql)
        applied.append(record)
    return sql, applied


def _word_pattern(word: str) -> re.Pattern[str]:
    return re.compile(rf"(?<!\w){re.escape(word)}(?!\w)", re.IGNORECASE)


def _table_in_query(table: str, sql: str) -> bool:
    # Tokens are stripped first so a token's own text cannot bring its table
    # into scope. A word match rather than a parse, which is the same
    # heuristic that picks entries for first touch.
    return bool(_word_pattern(table).search(_TOKEN.sub("", sql)))


def _resolve_token(token: str, sql: str, records: list[ExportRecord]) -> ExportRecord:
    if "::" in token:
        table, _, name = token.partition("::")
        return _resolve_qualified(table, name, token, sql, records)

    named = [record for record in records if record.name == token]
    if not named:
        if not _LEGACY_DOTTED.match(token):
            _abort_unknown(token, records)
        table, _, name = token.rpartition(".")
        return _resolve_qualified(table, name, token, sql, records)

    in_scope = [record for record in named if _table_in_query(record.table, sql)]
    if len(in_scope) == 1:
        return in_scope[0]
    if not in_scope:
        tables = ", ".join(sorted({record.table for record in named}))
        raise ValueError(
            f"{{{{{token}}}}} is defined on table {tables}, which does not "
            "appear in this query."
        )
    qualified = " or ".join(f"{{{{{record.table}::{token}}}}}" for record in in_scope)
    raise ValueError(
        f"{{{{{token}}}}} is ambiguous here: it is defined on several tables in "
        f"this query. Qualify the token: {qualified}."
    )


def _resolve_qualified(
    table: str, name: str, token: str, sql: str, records: list[ExportRecord]
) -> ExportRecord:
    hits = [
        record for record in records if record.table == table and record.name == name
    ]
    if not hits:
        _abort_unknown(token, records)
    if not _table_in_query(table, sql):
        raise ValueError(
            f"{{{{{token}}}}} is defined on table {table}, which does not appear "
            "in this query."
        )
    return hits[0]


def _abort_unknown(token: str, records: list[ExportRecord]) -> None:
    if not records:
        detail = "This source has no governed definitions."
    else:
        available = ", ".join(f"{{{{{r.name}}}}} ({r.table})" for r in records)
        detail = f"Available definitions: {available}."
    raise ValueError(f"No governed definition matches {{{{{token}}}}}. {detail}")


# ---- rendering -----------------------------------------------------------


def _flatten_inline(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _index_lines(registry: Registry) -> list[str]:
    records = registry.records
    if not records:
        return []
    multi_source = len({record.source for record in records}) > 1

    def scope(record: ExportRecord) -> str:
        return f"{record.source}.{record.table}" if multi_source else record.table

    lines: list[str] = []
    for one in dict.fromkeys(scope(record) for record in records):
        here = [record for record in records if scope(record) == one]
        parts = []
        for kind, plural in _GROUPS.items():
            items = [
                f"`{{{{{record.name}}}}}` ({_flatten_inline(record.label)})"
                if record.label
                else f"`{{{{{record.name}}}}}`"
                for record in here
                if record.kind == kind
            ]
            if items:
                parts.append(f"{plural} {', '.join(items)}")
        lines.append(f"- {one}: {'; '.join(parts)}")
    return lines


def index_text(registry: Registry, cap_chars: int = INDEX_CAP_CHARS) -> str:
    """The kind index for the system prompt, truncated to the cap."""
    kept: list[str] = []
    for line in _index_lines(registry):
        # Measured as joined, so the newlines between lines count against the
        # cap rather than pushing the result past it.
        if len("\n".join([*kept, line])) > cap_chars:
            break
        kept.append(line)
    return "\n".join(kept)


def index_overflows(registry: Registry, cap_chars: int = INDEX_CAP_CHARS) -> bool:
    """Whether the index did not fit, so the model is told to search instead."""
    return len("\n".join(_index_lines(registry))) > cap_chars


def _gist(record: ExportRecord) -> str:
    detail = _flatten_inline(
        " ".join(part for part in (record.description, record.details) if part)
    )
    # An absent type is left out rather than printed: data-dict omits it when
    # no single type is inferred, and the language's null spelling would
    # otherwise reach the model as a word.
    scope = f"{record.kind}, {record.type}" if record.type else record.kind
    parts = [f"({scope})"]
    if detail:
        parts.append(detail)
    parts.append(f"Selected {record.target}: `({_flatten_inline(record.sql)})`.")
    if record.notes:
        parts.append(f"Translation notes: {' '.join(record.notes)}")
    return " ".join(parts)


def entry_text(records: list[ExportRecord]) -> str | None:
    """A table's governed definitions, delivered at first touch.

    Shows the compiled SQL, never the authored expression: the expression is
    in data-dict's language, and the model writes SQL.
    """
    if not records:
        return None
    header = (
        "Governed definitions (write as `{{name}}` tokens in SQL; use "
        "`{{table::name}}` to qualify):\n\n"
    )
    lines = [f"- `{{{{{record.name}}}}}` {_gist(record)}" for record in records]
    return header + "\n".join(lines)


def context_chunks(records: list[ExportRecord]) -> list[str]:
    """One retrievable chunk per definition."""
    return [
        f"Governed definition `{{{{{record.name}}}}}` on table `{record.table}` "
        f"{_gist(record)}"
        for record in records
    ]


def applied_text(applied: list[ExportRecord]) -> str | None:
    """What each expanded token became, reported alongside a query's results."""
    if not applied:
        return None
    lines = []
    for record in applied:
        line = (
            f"- {{{{{record.name}}}}} ({record.table}): {record.target} "
            f"`({_flatten_inline(record.sql)})`"
        )
        if record.notes:
            line += f"\n  Translation notes: {' '.join(record.notes)}"
        lines.append(line)
    return "Applied governed definitions:\n\n" + "\n".join(lines)

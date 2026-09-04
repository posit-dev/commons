"""Read a data dictionary and render the three channels it feeds.

The input is the authored ``data-dict.yaml``, never data-dict's JSON export,
so the schema validated here is the published data-dict spec. Parsing is
permissive about fields commons never inspects and strict about the shape it
does: a ``number(quantity)`` column with no ``range`` reads without complaint,
because nothing reads that range.

Prose fields stay as authored markdown, because they reach the model verbatim.

Reading a dictionary also type-checks any ``definitions:`` blocks against
data-dict's expression language, so an unusable definition raises here,
before any source exists. Only the lowering to SQL waits for a dialect.

The three channels are methods rather than separate structures.
``pkg-r`` spreads the same rendering across ``R/data-dictionary.R``,
``R/prompt.R`` and ``R/context-layer.R``; here the dictionary owns it and the
prompt and context layers call in. That is a difference in shape, not in what
either produces.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, ConfigDict, model_validator

__all__ = [
    "Column",
    "DataDictionary",
    "Definition",
    "Relationship",
    "Table",
    "as_data_dictionary",
]

AMBIENT_GLOSSARY_CAP_CHARS = 4000


def _prose(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, list):
        return "\n".join(str(item) for item in value)
    return str(value)


def _key_by_name(entries: Any, what: str) -> dict[str, Any]:
    """data-dict lists tables and columns as sequences with a `name` field.

    Key them by that name for lookup. A pre-keyed mapping is accepted as-is.
    """
    if not entries:
        return {}
    if isinstance(entries, dict):
        return {str(key): value or {} for key, value in entries.items()}

    keyed: dict[str, Any] = {}
    for entry in entries:
        name = entry.get("name") if isinstance(entry, dict) else None
        if not isinstance(name, str) or not name:
            raise ValueError(f"Each {what} in a data dictionary needs a name.")
        keyed[name] = {key: value for key, value in entry.items() if key != "name"}
    return keyed


class _Permissive(BaseModel):
    model_config = ConfigDict(extra="ignore")


class Column(_Permissive):
    type: str | None = None
    description: str | None = None
    details: str | None = None
    units: str | None = None
    nullable: bool | None = None
    values: Any = None
    range: list[Any] | None = None
    examples: list[Any] | None = None
    constraints: list[str] | None = None


class Definition(_Permissive):
    """One authored governed definition, as written in the YAML.

    `expr` is optional here and required by the export spec, which is what
    type-checks it and reports where it went wrong. Requiring it twice would
    mean two places to keep in step.
    """

    expr: str | None = None
    label: str | None = None
    description: str | None = None
    details: str | None = None
    todo: str | None = None


class Table(_Permissive):
    description: str | None = None
    details: str | None = None
    columns: dict[str, Column] = {}
    definitions: dict[str, Definition] = {}
    # Attached by _definitions at data-source construction; empty until then,
    # so the registry can be exercised without the compiler. Elements are
    # ExportRecord, typed Any so this model need not import _definitions.
    compiled_definitions: list[Any] = []
    # The name the author wrote, kept when a catalog import re-keys this
    # table to the warehouse label, so first touch and relationship matching
    # can still find it.
    authored_name: str | None = None

    @model_validator(mode="before")
    @classmethod
    def _key_children(cls, data: Any) -> Any:
        if not isinstance(data, dict):
            return data
        data = dict(data)
        data["columns"] = _key_by_name(data.get("columns"), "column")
        data["definitions"] = _key_by_name(data.get("definitions"), "definition")
        return data


class Relationship(_Permissive):
    join: str | None = None
    cardinality: str | None = None
    description: str | None = None


class DataDictionary(_Permissive):
    name: str | None = None
    description: str | None = None
    details: str | None = None
    tables: dict[str, Table] = {}
    relationships: list[Relationship] = []
    glossary: dict[str, str] = {}
    # Phase 1 of the compiler, keyed by table name. Source-independent, so it
    # is produced here; the SQL needs a dialect and waits for `data_source()`.
    # Values map each definition name to its
    # `_definitions._export.DefinitionExport`, typed loosely so this module
    # need not import the compiler's types.
    definition_exports: dict[str, Any] = {}

    @model_validator(mode="before")
    @classmethod
    def _normalize(cls, data: Any) -> Any:
        if not isinstance(data, dict):
            return data
        data = dict(data)
        data["tables"] = _key_by_name(data.get("tables"), "table")
        # Type-checked here rather than at `data_source()` so an unusable
        # definition is reported when the dictionary is read, before any
        # source exists. Only the lowering to SQL needs a dialect.
        from ._definitions._export import export_spec

        data["definition_exports"] = {
            name: table.definitions for name, table in export_spec(data).items()
        }
        for field in ("name", "description", "details"):
            data[field] = _prose(data.get(field))
        relationships = data.get("relationships") or []
        data["relationships"] = [
            item for item in relationships if isinstance(item, dict)
        ]
        glossary = data.get("glossary") or {}
        data["glossary"] = {
            str(term): _prose(body) or "" for term, body in glossary.items() if term
        }
        return data

    @classmethod
    def from_path(cls, path: str | Path) -> DataDictionary:
        """Read a data-dict.yaml file. The YAML is the only input."""
        text = Path(path).read_text(encoding="utf-8")
        return cls.model_validate(yaml.safe_load(text) or {})

    # ---- channel 1: always in the prompt ---------------------------------

    def ambient_prompt_text(self) -> str:
        """The prose that goes into every system prompt for this source."""
        return "\n\n".join(part for part in (self.description, self.details) if part)

    def ambient_glossary_terms(
        self, cap_chars: int = AMBIENT_GLOSSARY_CAP_CHARS
    ) -> list[str]:
        """Glossary terms that fit the ambient cap, in order of appearance.

        Entries past the cap are co-resolved at first touch and searchable
        through the context layer, so nothing is lost by capping.
        """
        terms: list[str] = []
        used = 0
        for term, body in self.glossary.items():
            used += len(term) + len(body)
            if used > cap_chars:
                break
            terms.append(term)
        return terms

    # ---- channel 2: first touch ------------------------------------------

    def entry_text(
        self, table: str, ambient_cap_chars: int = AMBIENT_GLOSSARY_CAP_CHARS
    ) -> str | None:
        """The full entry for one table, delivered the first time it is used."""
        entry = self.tables.get(table)
        if entry is None:
            return None
        columns = self._columns_text(entry)
        if columns is not None:
            columns = f"Documented columns:\n\n{columns}"
        parts = self.entry_parts(table, columns, ambient_cap_chars=ambient_cap_chars)
        return "\n\n".join([f"Dictionary entry for `{table}`:", *parts])

    def entry_parts(
        self,
        table: str,
        columns_text: str | None,
        ambient_cap_chars: int = AMBIENT_GLOSSARY_CAP_CHARS,
    ) -> list[str]:
        """The body of a table's entry, without the heading.

        `describe_table` composes its own body from these, so it can merge the
        live schema and keep sample rows.
        """
        entry = self.tables.get(table)
        if entry is None:
            return []
        # Imported here because _definitions does not import this module and
        # this keeps it that way.
        from ._definitions import entry_text as definitions_entry_text

        parts = [
            part
            for part in (
                entry.description,
                entry.details,
                columns_text,
                definitions_entry_text(entry.compiled_definitions),
                self._relationships_text(table, entry.authored_name),
            )
            if part
        ]
        terms = self._terms_text("\n".join(parts), ambient_cap_chars)
        return [*parts, terms] if terms else parts

    def _columns_text(self, entry: Table) -> str | None:
        if not entry.columns:
            return None
        return "\n".join(
            _column_line(name, column) for name, column in entry.columns.items()
        )

    def _relationships_text(
        self, table: str, authored_name: str | None = None
    ) -> str | None:
        """Relationships mentioning this table, under either of its names.

        A catalog import re-keys a table to its warehouse label, while the
        relationship prose still says what the author wrote, so both names
        have to match or the join disappears from the entry.
        """
        names = [table, authored_name] if authored_name else [table]
        lines = []
        for relationship in self.relationships:
            text = " ".join(
                part for part in (relationship.join, relationship.description) if part
            )
            if not any(_word_pattern(name).search(text) for name in names):
                continue
            head = " ".join(
                part
                for part in (
                    relationship.join,
                    f"({relationship.cardinality})"
                    if relationship.cardinality
                    else None,
                )
                if part
            )
            body = _flatten_inline(relationship.description or "")
            if not head:
                lines.append(f"- {body}")
            elif body:
                lines.append(f"- {head}: {body}")
            else:
                lines.append(f"- {head}")
        if not lines:
            return None
        return "Relationships:\n\n" + "\n".join(lines)

    def _terms_text(self, text: str, ambient_cap_chars: int) -> str | None:
        """Glossary terms the entry mentions that the prompt does not carry."""
        ambient = set(self.ambient_glossary_terms(ambient_cap_chars))
        hits = [
            term
            for term in self.glossary
            if term not in ambient and _word_pattern(term).search(text)
        ]
        if not hits:
            return None
        lines = [f"- {term}: {_flatten_inline(self.glossary[term])}" for term in hits]
        return "Definitions:\n\n" + "\n".join(lines)

    # ---- channel 3: the search index -------------------------------------

    def context_chunks(self) -> list[str]:
        """Table- and dictionary-level prose, chunked for retrieval.

        Column-level content stays out: first touch owns it, and indexing it
        would pay for a second copy the agent already has.
        """
        chunks: list[str] = []
        if self.details:
            chunks.append(self.details)
        for name, entry in self.tables.items():
            prose = "\n\n".join(
                part for part in (entry.description, entry.details) if part
            )
            if prose:
                chunks.append(f"Table `{name}`: {prose}")
        chunks.extend(f"{term}: {body}" for term, body in self.glossary.items())
        from ._definitions import context_chunks as definitions_context_chunks

        for entry in self.tables.values():
            chunks.extend(definitions_context_chunks(entry.compiled_definitions))
        return [chunk for chunk in chunks if chunk]


def as_data_dictionary(x: Any) -> DataDictionary | None:
    if x is None or isinstance(x, DataDictionary):
        return x
    if isinstance(x, (str, Path)):
        return DataDictionary.from_path(x)
    raise TypeError(
        f"dictionary must be a path to a data-dict.yaml file, got {type(x).__name__}."
    )


def _flatten_inline(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _word_pattern(word: str) -> re.Pattern[str]:
    return re.compile(rf"(?<!\w){re.escape(word)}(?!\w)", re.IGNORECASE)


def _column_line(name: str, spec: Column) -> str:
    qualifier = ", ".join(
        str(part)
        for part in (
            spec.type,
            _nullability_fact(spec.nullable),
            spec.units,
            *(spec.constraints or []),
        )
        if part
    )
    facts = [
        part
        for part in (
            spec.description,
            _values_fact(spec.values),
            _range_fact(spec.range),
            _examples_fact(spec.examples),
            spec.details,
        )
        if part
    ]
    detail = _flatten_inline(" ".join(facts))

    line = f"- {name}"
    if qualifier:
        line = f"{line} ({qualifier})"
    if detail:
        line = f"{line}: {detail}"
    return line


def _nullability_fact(nullable: bool | None) -> str | None:
    if nullable is None:
        return None
    return "nullable" if nullable else "not nullable"


def _values_fact(values: Any) -> str | None:
    """`values` is a sequence ([M, F]) or a map of value to meaning ({M: Male})."""
    if not values:
        return None
    if isinstance(values, dict):
        rendered = [f"{value} ({label})" for value, label in values.items()]
    else:
        rendered = [str(value) for value in values]
    return f"Values: {', '.join(rendered)}."


def _range_fact(bounds: list[Any] | None) -> str | None:
    if not bounds or len(bounds) < 2:
        return None
    return f"Range: {bounds[0]} to {bounds[1]}."


def _examples_fact(examples: list[Any] | None) -> str | None:
    if not examples:
        return None
    return f"Examples: {', '.join(str(item) for item in examples)}."

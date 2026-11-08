"""Warehouse semantic models: records, typed parameters, and argument checks.

``pkg-r/R/semantic-models.R`` and ``pkg-r/R/semantic-calculations.R`` define
the same records and validation for R.
"""

from __future__ import annotations

import datetime as dt
import math
import re
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from typing import Any

from ._data_source import TableId

_TYPES = ("string", "integer", "number", "logical", "date", "datetime")


@dataclass(frozen=True)
class SemanticMember:
    """A dimension, metric, fact, or filter of a semantic model."""

    name: str
    kind: str
    parent: str | None = None
    label: str | None = None
    description: str | None = None
    type: str | None = None
    synonyms: tuple[str, ...] = ()
    filter: bool = False


@dataclass(frozen=True)
class TypedParameter:
    """A named, typed parameter of a semantic model."""

    name: str
    type: str
    description: str | None
    default: Any
    has_default: bool
    sql_type: str | None = None

    def __post_init__(self) -> None:
        if self.type not in _TYPES:
            raise ValueError(f"Parameter {self.name!r} has unknown type {self.type!r}.")
        if self.has_default:
            _check_value(self.name, self.default, self.type)


def _context(values: list[str]) -> list[str]:
    return list(dict.fromkeys(v for v in values if v))


@dataclass
class SemanticModel:
    id: TableId
    name: str
    backend: str
    description: str | None = None
    identity: TableId | None = None
    dimensions: list[SemanticMember] = field(default_factory=list)
    metrics: list[SemanticMember] = field(default_factory=list)
    facts: list[SemanticMember] = field(default_factory=list)
    filters: list[SemanticMember] = field(default_factory=list)
    parameters: dict[str, TypedParameter] = field(default_factory=dict)
    dependencies: list[TableId] = field(default_factory=list)
    dependencies_complete: bool = True
    relationships: list[Any] = field(default_factory=list)
    first_touch: list[str] = field(default_factory=list)
    retrieval: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.identity is None:
            self.identity = self.id
        self.first_touch = _context(self.first_touch)
        self.retrieval = _context(self.retrieval)


@dataclass
class SemanticStub:
    """A semantic model listed but not yet read from the warehouse."""

    id: TableId
    backend: str
    description: str | None = None
    identity: TableId | None = None

    @property
    def kind(self) -> str:
        if self.backend == "snowflake_semantic_view":
            return "semantic_view"
        return "semantic_model"


class UnsupportedSemanticParameter(ValueError):
    """A semantic parameter declares a type commons cannot bind."""


def spec_entries(entries: Any) -> list[dict[str, Any]]:
    """Normalize a list or name-keyed mapping of entries to a list of dicts."""
    if not entries:
        return []
    if isinstance(entries, Mapping):
        out = []
        for name, entry in entries.items():
            entry = dict(entry or {})
            if entry.get("name") is None and name:
                entry["name"] = name
            out.append(entry)
        return out
    return [dict(entry) for entry in entries]


def parameter_type(declared: Any) -> str | None:
    """Map a Snowflake data type to a parameter type, or None if unsupported."""
    if not isinstance(declared, str) or not declared.strip():
        return None
    text = declared.strip()
    base = re.sub(r"\s*\(.*$", "", text).upper()
    if base in ("STRING", "TEXT", "VARCHAR", "CHAR"):
        return "string"
    if base in ("BYTEINT", "SMALLINT", "INT", "INTEGER", "BIGINT"):
        return "integer"
    if base in ("NUMBER", "NUMERIC", "DECIMAL"):
        # A fraction cast to scale 0 rounds silently, so scale 0 is an integer
        # parameter that rejects fractions instead.
        scale = re.search(r",\s*([0-9]+)\s*\)", text)
        return "number" if scale and int(scale.group(1)) != 0 else "integer"
    if base in ("FLOAT", "DOUBLE", "REAL"):
        return "number"
    if base in ("BOOL", "BOOLEAN"):
        return "logical"
    if base == "DATE":
        return "date"
    if base.startswith("TIMESTAMP") or base == "DATETIME":
        return "datetime"
    return None


def _coerce_default(value: Any, type_: str) -> Any:
    if value is None or isinstance(value, (list, dict)):
        return value
    if type_ == "string":
        return str(value)
    if type_ in ("integer", "number"):
        try:
            return float(value)
        except (TypeError, ValueError, OverflowError):
            return math.nan
    if type_ == "logical":
        if isinstance(value, bool):
            return value
        text = str(value).lower()
        return text == "true" if text in ("true", "false") else None
    return str(value)


def parameters_from_spec(entries: Any, backend: str) -> dict[str, TypedParameter]:
    default_field = "default_value" if backend == "Snowflake" else "default"
    parameters: dict[str, TypedParameter] = {}
    for entry in spec_entries(entries):
        name = entry.get("name")
        declared = entry.get("data_type") or entry.get("type")
        type_ = parameter_type(declared)
        if not isinstance(name, str) or not name or type_ is None:
            raise UnsupportedSemanticParameter(
                f"{backend} semantic parameter "
                f"{(name if name is not None else 'unnamed')!r} has "
                f"unsupported type "
                f"{(declared if declared is not None else 'missing')!r}."
            )
        if name in parameters:
            raise ValueError(f"{backend} semantic parameter names must be unique.")
        has_default = default_field in entry
        description = entry.get("description") or entry.get("comment")
        parameters[name] = TypedParameter(
            name=name,
            type=type_,
            description=description,
            default=(
                _coerce_default(entry[default_field], type_) if has_default else None
            ),
            has_default=has_default,
        )
    return parameters


def _vals(names: list[str]) -> str:
    return ", ".join(repr(n) for n in names)


def _plural(names: list[str]) -> str:
    return "argument" if len(names) == 1 else "arguments"


_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}")
_DATETIME_RE = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T]"
    r"[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?"
    r"(Z|[+-][0-9]{2}:[0-9]{2})?"
)


def _valid_date(value: str) -> bool:
    if not _DATE_RE.fullmatch(value):
        return False
    try:
        dt.date.fromisoformat(value)
    except ValueError:
        return False
    return True


def _valid_datetime(value: str) -> bool:
    if not _DATETIME_RE.fullmatch(value):
        return False
    hour, minute = int(value[11:13]), int(value[14:16])
    second = int(value[17:19]) if value[16:17] == ":" else 0
    offset = re.search(r"[+-]([0-9]{2}):([0-9]{2})$", value)
    if offset and (int(offset.group(1)) > 23 or int(offset.group(2)) > 59):
        return False
    return _valid_date(value[:10]) and hour <= 23 and minute <= 59 and second <= 59


def _is_number(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        try:
            return math.isfinite(float(value))
        except OverflowError:
            return False
    return isinstance(value, float) and math.isfinite(value)


def _is_valid(value: Any, type_: str) -> bool:
    if type_ == "string":
        return isinstance(value, str)
    if type_ == "integer":
        return _is_number(value) and abs(value) < 2**53 and value == math.trunc(value)
    if type_ == "number":
        return _is_number(value)
    if type_ == "logical":
        return isinstance(value, bool)
    if type_ == "date":
        return isinstance(value, str) and _valid_date(value)
    return isinstance(value, str) and _valid_datetime(value)


def _check_value(name: str, value: Any, type_: str) -> None:
    if (
        value is None
        or isinstance(value, (list, tuple, dict, set))
        or (isinstance(value, float) and math.isnan(value))
    ):
        raise ValueError(f"Argument {name!r} must be one non-missing value.")
    if not _is_valid(value, type_):
        article = "an" if type_ == "integer" else "a"
        raise ValueError(f"Argument {name!r} must be {article} {type_} value.")


def validate_arguments(
    parameters: Mapping[str, TypedParameter], supplied: Mapping[str, Any]
) -> dict[str, Any]:
    """Check supplied values against parameters and return the supplied ones.

    Defaults are not filled in: an unsupplied parameter is left out so the
    warehouse applies its own default. Results follow declaration order.
    """
    if any(not isinstance(k, str) or not k for k in supplied):
        raise ValueError("`arguments` must have unique, non-empty names.")
    extra = [n for n in supplied if n not in parameters]
    if extra:
        raise ValueError(f"Unexpected {_plural(extra)}: {_vals(extra)}.")
    missing = [
        n for n, p in parameters.items() if not p.has_default and n not in supplied
    ]
    if missing:
        raise ValueError(f"Missing required {_plural(missing)}: {_vals(missing)}.")
    values: dict[str, Any] = {}
    for name, spec in parameters.items():
        if name not in supplied:
            continue
        value = supplied[name]
        _check_value(name, value, spec.type)
        values[name] = value
    return values


def members_context(members: list[SemanticMember], heading: str) -> list[str]:
    """Members as one context block, or nothing when there are none."""
    if not members:
        return []
    lines = [f"{heading}:"]
    for member in members:
        reference = ".".join(part for part in (member.parent, member.name) if part)
        detail = member.label if member.description is None else member.description
        line = f"- `{reference}`"
        if detail:
            line += f": {detail}"
        if member.filter:
            line += " (usable as a named filter)"
        lines.append(line)
    return ["\n".join(lines)]


@dataclass(frozen=True)
class MemberRow:
    """One member a semantic model offers, with the model and source it is on."""

    name: str
    model: str
    source: str
    kind: str
    parent: str | None
    label: str | None
    description: str | None
    type: str | None
    synonyms: str
    filter: bool


@dataclass(frozen=True)
class StubRow:
    """One semantic model listed but not yet read."""

    name: str
    model: str
    source: str
    backend: str
    description: str | None


@dataclass
class SemanticRegistry:
    members: list[MemberRow] = field(default_factory=list)
    # Each model's parameters, keyed by source label and model label.
    parameters: dict[tuple[str, str], dict[str, TypedParameter]] = field(
        default_factory=dict
    )
    stubs: list[StubRow] = field(default_factory=list)

    def for_source(self, source: str) -> list[MemberRow]:
        return [row for row in self.members if row.source == source]

    def has_metrics(self) -> bool:
        return any(row.kind == "metric" for row in self.members)


def semantic_registry(sources: Mapping[str, Any]) -> SemanticRegistry:
    """Every source's semantic members and stubs, in one registry.

    A model lists its dimensions, its metrics, and the facts labelled as
    filters; its named filters and other facts are context only.
    """
    registry = SemanticRegistry()
    for source_label, source in sources.items():
        for model_label, model in source.semantic_models.items():
            registry.parameters[(source_label, model_label)] = dict(model.parameters)
            for member in [
                *model.dimensions,
                *model.metrics,
                *(fact for fact in model.facts if fact.filter),
            ]:
                registry.members.append(
                    MemberRow(
                        name=member.name,
                        model=model_label,
                        source=source_label,
                        kind=member.kind,
                        parent=member.parent,
                        label=member.label,
                        description=member.description,
                        type=member.type,
                        synonyms=" ".join(member.synonyms),
                        filter=member.filter,
                    )
                )
        for model_label, stub in source.semantic_stubs.items():
            registry.stubs.append(
                StubRow(
                    name=stub.id.table,
                    model=model_label,
                    source=source_label,
                    backend=stub.backend,
                    description=stub.description,
                )
            )
    return registry


def member_aliases(row: MemberRow) -> list[str]:
    """Every name a member answers to; the last, fully qualified, is its key."""
    aliases = [row.name]
    if row.parent:
        aliases.append(f"{row.parent}.{row.name}")
    aliases.append(f"{row.model}::{row.name}")
    if row.parent:
        aliases.append(f"{row.model}::{row.parent}.{row.name}")
    return list(dict.fromkeys(aliases))


def member_key(row: MemberRow) -> str:
    return member_aliases(row)[-1]


def member_candidates(name: str, rows: list[MemberRow]) -> list[MemberRow]:
    return [row for row in rows if name in member_aliases(row)]


def _strip_braces(name: str) -> str:
    from ._pool import _strip_token_braces

    return _strip_token_braces(name)


def resolve_member(name: str, rows: list[MemberRow], kind: str) -> MemberRow:
    named = member_candidates(name, rows)
    matched = [row for row in named if row.kind == kind]
    if len(matched) == 1:
        return matched[0]
    if matched:
        choices = list(dict.fromkeys(member_key(row) for row in matched))
        raise ValueError(
            f"Native semantic name {name!r} is ambiguous. Use a qualified name: "
            f"{_vals(choices)}."
        )
    if named:
        raise ValueError(f"{name!r} is a native {named[0].kind}, not a {kind}.")
    available = [row.name for row in rows if row.kind == kind]
    raise ValueError(
        f"No native semantic {kind} is named {name!r}. "
        f"Available {kind}s: {_vals(available)}."
    )


def resolve_members(
    names: list[str] | None, rows: list[MemberRow], kind: str
) -> list[MemberRow]:
    return [resolve_member(_strip_braces(name), rows, kind) for name in names or []]


def resolve_filters(names: list[str] | None, rows: list[MemberRow]) -> list[MemberRow]:
    """Resolve names against the members labelled as filters, as filters."""
    filters = [replace(row, kind="filter") for row in rows if row.filter]
    return resolve_members(names, filters, "filter")


def metric_origin(name: str, definitions: Sequence[Any], rows: list[MemberRow]) -> str:
    """Whether a metric name is a data-dict definition or a native metric."""
    from ._pool import _candidates

    name = _strip_braces(name)
    definition_named = _candidates(name, definitions)
    definition_metrics = [d for d in definition_named if d.kind == "metric"]
    semantic_named = member_candidates(name, rows)
    semantic_metrics = [row for row in semantic_named if row.kind == "metric"]
    matches = len(definition_metrics) + len(semantic_metrics)
    if matches == 1:
        return "definition" if definition_metrics else "semantic_model"
    if matches > 1:
        choices = [f"{d.table}::{d.name}" for d in definition_metrics] + [
            member_key(row) for row in semantic_metrics
        ]
        raise ValueError(
            f"Metric name {name!r} is ambiguous. Use a qualified name: {_vals(choices)}."
        )
    if definition_named or semantic_named:
        kinds = list(
            dict.fromkeys(
                [d.kind for d in definition_named] + [r.kind for r in semantic_named]
            )
        )
        raise ValueError(f"{name!r} is a {' or a '.join(kinds)}, not a metric.")
    available = [d.name for d in definitions if d.kind == "metric"] + [
        row.name for row in rows if row.kind == "metric"
    ]
    if available:
        raise ValueError(
            f"No governed metric is named {name!r}. Available metrics: {_vals(available)}."
        )
    raise ValueError(
        f"No governed metric is named {name!r}. No governed metrics are defined."
    )


_NUMERIC = re.compile(r"-?[0-9]+(\.[0-9]+)?")


def where_conditions(
    where: Any,
    rows: list[MemberRow],
    reference: Callable[[MemberRow], str],
    quote_string: Callable[[str], str],
) -> list[str]:
    """Each `where` entry as a comparison on a native dimension."""
    from ._pool import WHERE_OPERATORS

    if not where:
        return []
    entries = [where] if isinstance(where, Mapping) else list(where)
    conditions = []
    for entry in entries:
        if not isinstance(entry, Mapping):
            raise TypeError(
                "Each `where` entry needs column, op, and value, as an object."
            )
        values = {}
        for key in ("column", "op", "value"):
            value = entry.get(key)
            if value is None or not str(value):
                raise ValueError("Each `where` entry needs column, op, and value.")
            values[key] = str(value)
        if values["op"] not in WHERE_OPERATORS:
            raise ValueError(
                f"`where` operator must be one of {_vals(list(WHERE_OPERATORS))}, "
                f"not {values['op']!r}."
            )
        dimension = resolve_member(values["column"], rows, "dimension")
        literal = (
            values["value"]
            if not entry.get("quoted") and _NUMERIC.fullmatch(values["value"])
            else quote_string(values["value"])
        )
        conditions.append(f"({reference(dimension)} {values['op']} {literal})")
    return conditions

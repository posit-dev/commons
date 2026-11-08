"""Warehouse semantic models: records, typed parameters, and argument checks.

``pkg-r/R/semantic-models.R`` and ``pkg-r/R/semantic-calculations.R`` define
the same records and validation for R.
"""

from __future__ import annotations

import datetime as dt
import math
import re
from collections.abc import Mapping
from dataclasses import dataclass, field
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

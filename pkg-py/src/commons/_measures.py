"""The semantic layer: trusted calculations an agent can run.

A measure's signature carries both kinds of argument. Parameters annotated
``Annotated[T, Field(description=...)]`` are supplied by the model; parameters
annotated ``Injected[T]`` are supplied by commons at call time and never reach
the model. A parameter that is neither is an error, so an argument cannot be
hidden from the model by forgetting to describe it.

``pkg-r/R/measures.R`` implements the same semantic layer for R.
"""

from __future__ import annotations

import inspect
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import (
    Annotated,
    Any,
    Final,
    TypeVar,
    cast,
    get_args,
    get_origin,
    get_type_hints,
)

from pydantic import BaseModel, ConfigDict, create_model
from pydantic.fields import FieldInfo
from pydantic_core import PydanticUndefined


class _InjectedMarker:
    """Sentinel distinguishing a commons-supplied parameter from a described one."""

    def __repr__(self) -> str:
        return "Injected"


INJECTED: Final = _InjectedMarker()

_T = TypeVar("_T")

# `Injected[Engine]` expands to `Annotated[Engine, INJECTED]`, so the marker
# survives `get_type_hints(include_extras=True)` and stays out of the schema.
Injected = Annotated[_T, INJECTED]

MEASURE_ATTRIBUTE: Final = "__commons_measure__"


@dataclass(frozen=True)
class Measure:
    """A trusted calculation the agent can run.

    ``params`` describes only the arguments the model supplies; ``injected``
    names the arguments commons supplies, which the model never sees.
    """

    name: str
    title: str
    description: str
    func: Callable[..., Any]
    params: type[BaseModel]
    injected: tuple[str, ...] = ()
    provenance: tuple[str, ...] = ()

    def validate_args(self, args: Mapping[str, Any] | None) -> dict[str, Any]:
        """Check and coerce the model's arguments against the schema.

        The provider only ever sees ``call_measure``, so a measure's own
        arguments arrive unchecked and are validated here.
        """
        validated = self.params.model_validate(dict(args or {}))
        return validated.model_dump(exclude_unset=True)


def _split_parameters(
    func: Callable[..., Any],
) -> tuple[dict[str, tuple[Any, FieldInfo]], tuple[str, ...]]:
    if inspect.iscoroutinefunction(func) or inspect.isasyncgenfunction(func):
        raise TypeError(_async_message(func))

    try:
        hints = get_type_hints(func, include_extras=True)
    except NameError as error:
        raise TypeError(_unresolvable_hint_message(func, error)) from error

    fields: dict[str, tuple[Any, FieldInfo]] = {}
    injected: list[str] = []

    for name, param in inspect.signature(func).parameters.items():
        if param.kind is inspect.Parameter.VAR_POSITIONAL:
            raise TypeError(_unsupported_message(func, f"*{name}"))
        if param.kind is inspect.Parameter.VAR_KEYWORD:
            raise TypeError(_unsupported_message(func, f"**{name}"))
        if param.kind is inspect.Parameter.POSITIONAL_ONLY:
            raise TypeError(
                _unsupported_message(func, f"positional-only parameter {name!r}")
            )

        annotation = hints.get(name, inspect.Parameter.empty)
        field_meta = _described_field(annotation)
        if _is_injected(annotation):
            if field_meta is not None:
                raise TypeError(_dual_marker_message(func, name))
            injected.append(name)
            continue

        if field_meta is None:
            raise TypeError(_undeclared_message(func, name))

        if param.default is inspect.Parameter.empty:
            if _annotation_declares_default(annotation):
                raise TypeError(_annotation_default_message(func, name))
            default = PydanticUndefined
        else:
            default = param.default

        field = FieldInfo.from_annotated_attribute(annotation, default)
        fields[name] = (get_args(annotation)[0], field)

    return fields, tuple(injected)


def _is_injected(annotation: Any) -> bool:
    return get_origin(annotation) is Annotated and any(
        metadata is INJECTED for metadata in get_args(annotation)[1:]
    )


def _described_field(annotation: Any) -> FieldInfo | None:
    if get_origin(annotation) is not Annotated:
        return None
    for metadata in get_args(annotation)[1:]:
        if isinstance(metadata, FieldInfo) and (metadata.description or "").strip():
            return metadata
    return None


def _annotation_declares_default(annotation: Any) -> bool:
    # An annotation can carry more than one Field(...); the default can hide
    # in any of them, not just the one _described_field() returns.
    if get_origin(annotation) is not Annotated:
        return False
    return any(
        isinstance(metadata, FieldInfo)
        and (
            metadata.default is not PydanticUndefined
            or metadata.default_factory is not None
        )
        for metadata in get_args(annotation)[1:]
    )


def _undeclared_message(func: Callable[..., Any], name: str) -> str:
    return (
        f"Parameter {name!r} of measure {func.__name__!r} is neither described "
        f"nor injected.\n"
        f"Annotate it Annotated[T, Field(description=...)] for the model to "
        f"supply it, or Injected[T] for commons to supply it."
    )


def _dual_marker_message(func: Callable[..., Any], name: str) -> str:
    return (
        f"Parameter {name!r} of measure {func.__name__!r} is marked both "
        f"Injected and Field(description=...), so commons cannot tell "
        f"whether the model or commons supplies it.\n"
        f"Remove one of the two markers: Injected[T] if commons supplies "
        f"it, or Annotated[T, Field(description=...)] if the model does."
    )


def _unresolvable_hint_message(func: Callable[..., Any], error: NameError) -> str:
    name = error.name or str(error)
    return (
        f"Measure {func.__name__!r} has an annotation that could not be "
        f"resolved: {name!r} is not defined.\n"
        f"This usually means {name!r} is only imported under "
        f"`if TYPE_CHECKING:`. Import it unconditionally, or annotate the "
        f"parameter Injected[Any] instead."
    )


def _async_message(func: Callable[..., Any]) -> str:
    return (
        f"Measure {func.__name__!r} is defined with async def, but a "
        f"measure must be a synchronous function.\n"
        f"Define it with def instead of async def."
    )


def _annotation_default_message(func: Callable[..., Any], name: str) -> str:
    return (
        f"Parameter {name!r} of measure {func.__name__!r} declares a default "
        f"inside Field(...), but the signature has no default.\n"
        f"Python never applies the Field default, so a call that omits "
        f"{name!r} would fail. Put the default in the signature instead: "
        f"{name}: Annotated[T, Field(description=...)] = <default>."
    )


def _unsupported_message(func: Callable[..., Any], name: str) -> str:
    return (
        f"Measure {func.__name__!r} takes {name}, which has no schema.\n"
        f"Declare each argument explicitly."
    )


def measure(
    *,
    description: str | None = None,
    name: str | None = None,
    title: str | None = None,
    provenance: Sequence[str] = (),
) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Mark a function as a measure.

    The decorated function is returned unchanged, so measures and the helpers
    they call stay ordinary callables.
    """

    def decorate(func: Callable[..., Any]) -> Callable[..., Any]:
        text = description or inspect.getdoc(func) or ""
        if not text.strip():
            raise ValueError(
                f"Measure {func.__name__!r} has no description.\n"
                f"Pass description= to @measure, or give the function a docstring."
            )
        fields, injected = _split_parameters(func)
        resolved_name = name or func.__name__
        record = Measure(
            name=resolved_name,
            title=title or _humanize(resolved_name),
            description=text.strip(),
            func=func,
            params=create_model(
                resolved_name,
                __config__=ConfigDict(extra="forbid"),
                **cast(dict[str, Any], fields),
            ),
            injected=injected,
            provenance=tuple(provenance),
        )
        setattr(func, MEASURE_ATTRIBUTE, record)
        return func

    return decorate


def measure_schema_text(
    measure: Measure,
    source_names: Sequence[str] = (),
    heading: str | None = None,
) -> str:
    """Render the block search_pool shows the model for one measure.

    The exact text is a cross-language contract pinned by
    ``tests/shared/measure-schema.json``; change that fixture, not just this
    function.
    """
    schema = measure.params.model_json_schema()
    properties: dict[str, Any] = schema.get("properties", {})
    required = set(schema.get("required", ()))

    details = ""
    # Naming the source a measure queries points the SQL fallback at the right
    # one. `source_names` is empty for single-source agents, so the line never
    # appears there.
    named = [name for name in measure.injected if name in set(source_names)]
    if named:
        details += f"sources: {', '.join(named)}\n"
    if properties:
        lines = [
            f"  - {name} ({_argument_detail(prop)}, "
            f"{'required' if name in required else 'optional'}) "
            f"{prop.get('description', '')}"
            for name, prop in properties.items()
        ]
        details += "arguments:\n" + "\n".join(lines)
    details = details.removesuffix("\n")
    if details:
        details = f"\n\n{details}"

    return f"### {heading or measure.name}\n{measure.description}{details}"


def _argument_detail(prop: dict[str, Any]) -> str:
    if "enum" in prop:
        return f"one of {{{', '.join(str(value) for value in prop['enum'])}}}"
    if prop.get("type") == "array":
        return f"array of {{{_items_label(prop.get('items', {}))}}}"
    return str(prop.get("type", "string"))


def _items_label(items: dict[str, Any]) -> str:
    # An array's items can be an enum, whose vocabulary is worth listing, or a
    # basic type, which is named. Not `_argument_detail`: that would nest the
    # enum branch's "one of" inside "array of".
    if "enum" in items:
        return ", ".join(str(value) for value in items["enum"])
    return str(items.get("type", "string"))


def as_measure(obj: Any) -> Measure | None:
    """Recognize a measure, whether decorated function or bare record."""
    if isinstance(obj, Measure):
        return obj
    record = getattr(obj, MEASURE_ATTRIBUTE, None)
    return record if isinstance(record, Measure) else None


def _humanize(name: str) -> str:
    return name.replace("_", " ")

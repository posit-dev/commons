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
from collections.abc import Callable
from typing import Annotated, Any, Final, TypeVar, get_args, get_origin, get_type_hints

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


def _split_parameters(
    func: Callable[..., Any],
) -> tuple[dict[str, tuple[Any, FieldInfo]], tuple[str, ...]]:
    hints = get_type_hints(func, include_extras=True)
    fields: dict[str, tuple[Any, FieldInfo]] = {}
    injected: list[str] = []

    for name, param in inspect.signature(func).parameters.items():
        if param.kind is inspect.Parameter.VAR_POSITIONAL:
            raise TypeError(_unsupported_message(func, f"*{name}"))
        if param.kind is inspect.Parameter.VAR_KEYWORD:
            raise TypeError(_unsupported_message(func, f"**{name}"))

        annotation = hints.get(name, inspect.Parameter.empty)
        if _is_injected(annotation):
            injected.append(name)
            continue

        if _described_field(annotation) is None:
            raise TypeError(_undeclared_message(func, name))

        default = (
            param.default
            if param.default is not inspect.Parameter.empty
            else PydanticUndefined
        )
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


def _undeclared_message(func: Callable[..., Any], name: str) -> str:
    return (
        f"Parameter {name!r} of measure {func.__name__!r} is neither described "
        f"nor injected.\n"
        f"Annotate it Annotated[T, Field(description=...)] for the model to "
        f"supply it, or Injected[T] for commons to supply it."
    )


def _unsupported_message(func: Callable[..., Any], name: str) -> str:
    return (
        f"Measure {func.__name__!r} takes {name}, which has no schema.\n"
        f"Declare each argument explicitly."
    )

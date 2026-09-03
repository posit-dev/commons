"""The semantic layer: trusted calculations an agent can run.

A measure's signature carries both kinds of argument. Parameters annotated
``Annotated[T, Field(description=...)]`` are supplied by the model; parameters
annotated ``Injected[T]`` are supplied by commons at call time and never reach
the model. A parameter that is neither is an error, so an argument cannot be
hidden from the model by forgetting to describe it.

``pkg-r/R/measures.R`` implements the same semantic layer for R.
"""

from __future__ import annotations

import hashlib
import importlib.util
import inspect
import os
import re
import sys
import threading
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType, ModuleType
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
    they call stay ordinary callables. Model-supplied arguments are expected
    to be scalars, enums, or arrays of those; richer shapes are not rejected,
    but the schema block renders them only approximately.
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


def as_measure(obj: Any) -> Measure | None:
    """Recognize a measure, whether decorated function or bare record."""
    if isinstance(obj, Measure):
        return obj
    record = getattr(obj, MEASURE_ATTRIBUTE, None)
    return record if isinstance(record, Measure) else None


def _humanize(name: str) -> str:
    return name.replace("_", " ")


def measure_schema_text(
    record: Measure,
    source_names: Sequence[str] = (),
    heading: str | None = None,
) -> str:
    """Render the block search_pool shows the model for one measure.

    The exact text is a cross-language contract pinned by
    ``tests/shared/measure-schema.json``; change that fixture, not just this
    function.
    """
    schema = record.params.model_json_schema()
    properties: dict[str, Any] = schema.get("properties", {})
    required = set(schema.get("required", ()))
    defs: dict[str, Any] = schema.get("$defs", {})

    details = ""
    # Naming the source a measure queries points the SQL fallback at the right
    # one. `source_names` is empty for single-source agents, so the line never
    # appears there.
    named_sources = set(source_names)
    named = [name for name in record.injected if name in named_sources]
    if named:
        details += f"sources: {', '.join(named)}\n"
    if properties:
        lines = [
            f"  - {name} ({_argument_detail(prop, defs)}, "
            f"{'required' if name in required else 'optional'}) "
            f"{prop.get('description', '')}"
            for name, prop in properties.items()
        ]
        details += "arguments:\n" + "\n".join(lines)
    details = details.removesuffix("\n")
    if details:
        details = f"\n\n{details}"

    resolved_heading = record.name if heading is None else heading
    return f"### {resolved_heading}\n{record.description}{details}"


def _argument_detail(prop: dict[str, Any], defs: dict[str, Any]) -> str:
    resolved = _resolve_node(prop, defs)
    if "enum" in resolved:
        return f"one of {{{', '.join(str(value) for value in resolved['enum'])}}}"
    if resolved.get("type") == "array":
        return f"array of {{{_items_label(resolved.get('items', {}), defs)}}}"
    return str(resolved.get("type", "string"))


def _items_label(items: dict[str, Any], defs: dict[str, Any]) -> str:
    # An array's items can be an enum, whose vocabulary is worth listing, or a
    # basic type, which is named. Not `_argument_detail`: that would nest the
    # enum branch's "one of" inside "array of".
    resolved = _resolve_node(items, defs)
    if "enum" in resolved:
        return ", ".join(str(value) for value in resolved["enum"])
    return str(resolved.get("type", "string"))


def _resolve_node(node: dict[str, Any], defs: dict[str, Any]) -> dict[str, Any]:
    """Reduce a JSON Schema node to the single shape it actually describes.

    pydantic emits two shapes ``_argument_detail`` and ``_items_label`` must
    see through, in this order: a nullable field or item is an `anyOf` union
    with a `{"type": "null"}` branch, and a bare `enum.Enum` (unlike a
    `Literal`, which is inlined) is a `$ref` into `$defs`. Unwrapping the
    union before resolving the reference means a nullable bare enum, and a
    nullable array of them, both resolve the same as a required one.
    """
    return _resolve_ref(_unwrap_any_of(node), defs)


def _unwrap_any_of(node: dict[str, Any]) -> dict[str, Any]:
    branches = node.get("anyOf")
    if branches is None:
        return node
    non_null = [branch for branch in branches if branch.get("type") != "null"]
    # A union of more than one real type has no single detail to derive; leave
    # it as is; it falls through to `string` below, same as before this fix.
    return non_null[0] if len(non_null) == 1 else node


def _resolve_ref(node: dict[str, Any], defs: dict[str, Any]) -> dict[str, Any]:
    ref = node.get("$ref")
    if ref is None:
        return node
    return defs[ref.removeprefix("#/$defs/")]


@dataclass(frozen=True)
class SemanticLayer:
    """The trusted calculations an agent can run.

    ``source_text`` holds the source of the measures and the module-level
    helpers they call, keyed by Python name. Only text is kept: the agent's
    worker session reads measure definitions but never receives a callable.
    """

    measures: Mapping[str, Measure]
    source_text: Mapping[str, str]

    def __len__(self) -> int:
        return len(self.measures)

    def __repr__(self) -> str:
        count = len(self.measures)
        plural = "" if count == 1 else "s"
        return f"A commons semantic layer with {count} measure{plural}."


def semantic_layer(*items: Any) -> SemanticLayer:
    """Collect measures into a semantic layer.

    Each item is a measure, a list of measures, a module, or a path to a
    Python file or a directory of them. Directory searches are not recursive.

    A sibling file is imported by plain absolute import; its directory is on
    sys.path only while the file loads. A file whose name collides with the
    standard library, or with a module already imported from elsewhere, is a
    construction error.
    """
    measures: dict[str, Measure] = {}
    source_text: dict[str, str] = {}
    duplicates: list[str] = []

    for item in items:
        found, sources = _collect(item)
        for record in found:
            if record.name in measures:
                duplicates.append(record.name)
            measures[record.name] = record
        _merge_sources(source_text, sources)

    if duplicates:
        raise ValueError(
            f"Measure names must be unique; duplicated: "
            f"{', '.join(sorted(set(duplicates)))}.\n"
            f"Give one of the colliding measures a distinct name with "
            f"@measure(name=...)."
        )

    return SemanticLayer(
        measures=MappingProxyType(measures),
        source_text=MappingProxyType(source_text),
    )


def _collect(item: Any) -> tuple[list[Measure], dict[str, str]]:
    if isinstance(item, (list, tuple)):
        measures: list[Measure] = []
        sources: dict[str, str] = {}
        for entry in item:
            found, text = _collect(entry)
            measures.extend(found)
            _merge_sources(sources, text)
        return measures, sources

    if isinstance(item, ModuleType):
        return _from_module(item)

    if isinstance(item, (str, os.PathLike)):
        return _from_path(Path(item))

    record = as_measure(item)
    if record is None:
        raise TypeError(
            f"Every item in semantic_layer() must be a measure, a list of "
            f"measures, a module, or a path; got {item!r}.\n"
            f"Decorate the function with @measure to make it one."
        )
    return [record], {record.func.__name__: _source_text(record.func)}


def _from_path(path: Path) -> tuple[list[Measure], dict[str, str]]:
    if not path.exists():
        raise ValueError(
            f"Path does not exist: {path}.\n"
            f"semantic_layer() takes measures, modules, Python files, or "
            f"directories of them."
        )

    # Not recursive, and __init__.py is skipped: a directory of measure files
    # is a directory, not a package.
    files = (
        sorted(
            entry
            for entry in path.iterdir()
            if entry.suffix == ".py" and entry.name != "__init__.py"
        )
        if path.is_dir()
        else [path]
    )

    measures: list[Measure] = []
    sources: dict[str, str] = {}
    for file in files:
        found, text = _from_module(_load_module_from_path(file))
        measures.extend(found)
        _merge_sources(sources, text)
    return measures, sources


def _merge_sources(target: dict[str, str], found: Mapping[str, str]) -> None:
    """Merge harvested source text; the first definition of a name wins.

    Every place source text is combined across items uses this, so a new
    merge point cannot quietly pick the wrong precedence.
    """
    for name, text in found.items():
        target.setdefault(name, text)


def _from_module(module: ModuleType) -> tuple[list[Measure], dict[str, str]]:
    """Harvest a module's measures and the source of every function it defines.

    Helpers are harvested too, so the worker session can show the reasoning a
    measure delegates to. Imported names are skipped: they belong to the
    module they were defined in.
    """
    measures: list[Measure] = []
    sources: dict[str, str] = {}
    for name, value in vars(module).items():
        if not inspect.isfunction(value) or value.__module__ != module.__name__:
            continue
        sources[name] = _source_text(value)
        record = as_measure(value)
        if record is not None:
            measures.append(record)
    return measures, sources


# The import machinery (sys.path, sys.modules) is process-global state, not
# owned by any one SemanticLayer, so concurrent construction must serialize
# around it rather than around the layer itself. Reentrant, not a plain
# Lock: the lock is held across exec_module(), which runs a measure file's
# top-level code, and that code can itself call semantic_layer() on another
# path, re-entering this same function on the same thread.
_IMPORT_LOCK = threading.RLock()

# Anything that is not a plain identifier character, including the dots in a
# name like `sales.q3.py`: left alone, a dotted stem would still produce a
# dotted module name, defeating the single-segment name below.
_UNSAFE_NAME_CHARS = re.compile(r"[^0-9a-zA-Z_]")

# The mtime a path's cached module was loaded at, keyed by module name.
# Compared against the file's current mtime on every load so a module is
# reused only while its source is unchanged; sys.modules alone cannot tell a
# fresh load from a stale one.
_load_mtimes: dict[str, float] = {}


def _load_module_from_path(path: Path) -> ModuleType:
    resolved = path.resolve()
    stem = _UNSAFE_NAME_CHARS.sub("_", path.stem)
    # The digest, not a load counter: two semantic_layer() calls on the same
    # path should reuse the same module when its source is unchanged, rather
    # than each minting a new sys.modules entry the old one is never removed
    # from -- an application constructing an agent per session leaked one
    # module, and everything it held onto, per session. The cost is that a
    # file edited mid-process reloads under the same name, so an earlier
    # layer's Measure.func.__module__ then resolves to the newer module
    # object; a development-time scenario, not a session-count-scaling leak.
    #
    # A single path segment, not `commons._measure_sources.<stem>`: a dotted
    # name makes `commons._measure_sources` the loaded file's __package__,
    # so a relative import in the user's own file would resolve into
    # commons' internals instead of failing with Python's own "no known
    # parent package" error.
    digest = hashlib.sha256(str(resolved).encode()).hexdigest()[:8]
    name = f"_commons_measure_source_{stem}_{digest}"

    with _IMPORT_LOCK:
        mtime = resolved.stat().st_mtime
        cached = sys.modules.get(name)
        if cached is not None and _load_mtimes.get(name) == mtime:
            return cached

        _check_directory_importable(path.parent, requested=path)

        spec = importlib.util.spec_from_file_location(name, path)
        if spec is None or spec.loader is None:
            raise ValueError(
                f"Cannot read measures from {path}: not a Python file.\n"
                f"Pass a .py file, a directory of them, or a module object."
            )

        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        _load_mtimes[name] = mtime

        # Appended, not inserted at the front: a sibling file can then
        # import another sibling by plain absolute import, but a sibling
        # named like a stdlib module must not shadow it for the rest of the
        # process.
        directory = str(path.parent)
        added_to_path = directory not in sys.path
        if added_to_path:
            sys.path.append(directory)
        try:
            spec.loader.exec_module(module)
        except BaseException:
            if sys.modules.get(name) is module:
                sys.modules.pop(name, None)
            _load_mtimes.pop(name, None)
            raise
        finally:
            if added_to_path and directory in sys.path:
                sys.path.remove(directory)
        return module


def _check_directory_importable(directory: Path, requested: Path) -> None:
    """Fail before a directory goes on sys.path if a file in it would shadow
    an importable module or collide with one already loaded from elsewhere.

    Every .py file in the directory is checked, not only ``requested``: the
    sys.path entry makes all of them importable, so an unloaded file with a
    colliding name is exactly as dangerous. ``requested`` is named in every
    message so a sibling file's collision is not reported with nothing
    connecting it to the file the caller actually asked to load.
    """
    for entry in sorted(directory.glob("*.py")):
        if entry.name == "__init__.py":
            continue
        stem = entry.stem

        # Must run before the directory joins sys.path: added first, the
        # file would resolve to itself and every directory would look
        # shadowed. A stdlib name is always findable, so it is folded into
        # this check rather than tested separately, keeping exactly one
        # raise per entry. find_spec() also catches a module already cached
        # in sys.modules under this name (e.g. by an earlier measure
        # directory's sibling import), except when that cached entry has no
        # discoverable spec, which find_spec() reports by raising instead of
        # returning one; the sys.modules check below catches that case.
        try:
            spec = importlib.util.find_spec(stem)
        except (ImportError, ValueError):
            spec = None
        if spec is not None and (
            spec.origin is None or Path(spec.origin).resolve() != entry.resolve()
        ):
            if stem in sys.stdlib_module_names:
                raise ValueError(
                    f"While loading {requested}, {entry} collides with the "
                    f"standard library module {stem!r}; one of the two will "
                    f"be unreachable.\n"
                    f"Rename {entry}."
                )
            origin_note = f" ({spec.origin})" if spec.origin else ""
            raise ValueError(
                f"While loading {requested}, {entry} would be shadowed by "
                f"the already-importable module {stem!r}{origin_note}.\n"
                f"Rename {entry}."
            )

        existing = sys.modules.get(stem)
        existing_file = getattr(existing, "__file__", None) if existing else None
        if existing is not None and (
            existing_file is None or Path(existing_file).resolve() != entry.resolve()
        ):
            raise ValueError(
                f"While loading {requested}, {entry} collides with {stem!r}, "
                f"already imported from "
                f"{existing_file or 'a module with no file'}.\n"
                f"Rename {entry}."
            )


def _source_text(func: Callable[..., Any]) -> str:
    try:
        return inspect.getsource(func)
    except (OSError, TypeError):
        return f"# source unavailable for {func.__name__}"

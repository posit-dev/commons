"""The semantic layer: measures, their schemas, and injected arguments."""

import enum
import importlib
import inspect
import os
import py_compile
import sys
import threading
from collections.abc import AsyncIterator
from dataclasses import FrozenInstanceError
from pathlib import Path
from types import ModuleType
from typing import Annotated, Any, Literal, get_args, get_origin

import pytest
from pydantic import Field, ValidationError

from commons._measures import (
    INJECTED,
    Injected,
    Measure,
    _from_module,
    _load_module_from_path,
    _load_mtimes,
    _split_parameters,
    as_measure,
    measure,
    measure_schema_text,
    resolve_injections,
    semantic_layer,
)

from ._shared import load_shared_fixture


def test_injected_alias_carries_the_marker() -> None:
    alias = Injected[int]
    assert get_origin(alias) is Annotated
    assert get_args(alias) == (int, INJECTED)


def test_split_parameters_separates_described_from_injected() -> None:
    def revenue(
        region: Annotated[str, Field(description="The sales region.")],
        warehouse: Injected[Any],
    ) -> int:
        return 0

    fields, injected = _split_parameters(revenue)

    assert list(fields) == ["region"]
    assert injected == ("warehouse",)


def test_split_parameters_keeps_declaration_order() -> None:
    def m(
        b: Annotated[str, Field(description="B.")],
        a: Annotated[str, Field(description="A.")],
        con: Injected[Any] = None,
    ) -> None: ...

    fields, injected = _split_parameters(m)

    assert list(fields) == ["b", "a"]
    assert injected == ("con",)


def test_split_parameters_carries_defaults_into_the_field() -> None:
    def m(limit: Annotated[int, Field(description="Cap.")] = 10) -> None: ...

    fields, _ = _split_parameters(m)

    assert fields["limit"][1].default == 10


def test_field_default_without_signature_default_is_an_error() -> None:
    def m(limit: Annotated[int, Field(default=10, description="Cap.")]) -> None: ...

    with pytest.raises(TypeError) as excinfo:
        _split_parameters(m)

    message = str(excinfo.value)
    assert "limit" in message
    assert "m" in message
    assert "= <default>" in message


def test_field_default_factory_without_signature_default_is_an_error() -> None:
    def m(
        tags: Annotated[list[str], Field(default_factory=list, description="Tags.")],
    ) -> None: ...

    with pytest.raises(TypeError, match="tags"):
        _split_parameters(m)


def test_field_default_in_a_separate_metadata_item_is_an_error() -> None:
    def m(
        limit: Annotated[int, Field(default=10), Field(description="Cap.")],
    ) -> None: ...

    with pytest.raises(TypeError) as excinfo:
        _split_parameters(m)

    message = str(excinfo.value)
    assert "limit" in message
    assert "= <default>" in message


def test_field_default_factory_in_a_separate_metadata_item_is_an_error() -> None:
    def m(
        tags: Annotated[
            list[str], Field(default_factory=list), Field(description="Tags.")
        ],
    ) -> None: ...

    with pytest.raises(TypeError, match="tags"):
        _split_parameters(m)


def test_unannotated_parameter_is_an_error() -> None:
    def m(region) -> None: ...

    with pytest.raises(TypeError, match="region"):
        _split_parameters(m)


def test_bare_annotation_without_a_description_is_an_error() -> None:
    def m(region: str) -> None: ...

    with pytest.raises(TypeError) as excinfo:
        _split_parameters(m)

    message = str(excinfo.value)
    assert "region" in message
    assert "Field(description=" in message
    assert "Injected[" in message


def test_annotated_without_a_description_is_an_error() -> None:
    def m(region: Annotated[str, Field()]) -> None: ...

    with pytest.raises(TypeError, match="region"):
        _split_parameters(m)


def test_empty_description_is_an_error() -> None:
    def m(region: Annotated[str, Field(description="  ")]) -> None: ...

    with pytest.raises(TypeError, match="region"):
        _split_parameters(m)


def test_var_args_are_an_error() -> None:
    def m(*args: str) -> None: ...

    with pytest.raises(TypeError, match=r"\*args"):
        _split_parameters(m)


def test_var_kwargs_are_an_error() -> None:
    def m(**kwargs: str) -> None: ...

    with pytest.raises(TypeError, match=r"\*\*kwargs"):
        _split_parameters(m)


def test_positional_only_parameter_is_an_error() -> None:
    def m(region: Annotated[str, Field(description="The region.")], /) -> None: ...

    with pytest.raises(TypeError, match="region"):
        _split_parameters(m)


def test_async_def_measure_is_an_error() -> None:
    async def m(x: Annotated[str, Field(description="d")]) -> None: ...

    with pytest.raises(TypeError, match="async") as excinfo:
        _split_parameters(m)

    assert "m" in str(excinfo.value)


def test_async_generator_measure_is_an_error() -> None:
    # iscoroutinefunction() alone misses this: a `yield` inside an async def
    # makes it an async generator function, a different kind entirely.
    async def m(x: Annotated[str, Field(description="d")]) -> AsyncIterator[str]:
        yield x

    with pytest.raises(TypeError, match="async") as excinfo:
        _split_parameters(m)

    assert "m" in str(excinfo.value)


def test_unresolvable_annotation_names_the_measure_and_the_missing_name() -> None:
    # Mimics a TYPE_CHECKING-only import: the annotation is a forward
    # reference get_type_hints() cannot resolve at runtime. Built via exec so
    # the missing name is never visible to static analysis of this file.
    namespace: dict[str, Any] = {"Injected": Injected}
    exec("def m(conn: 'Injected[NoSuchConnection]') -> None: ...", namespace)  # noqa: S102
    m = namespace["m"]

    with pytest.raises(TypeError) as excinfo:
        _split_parameters(m)

    message = str(excinfo.value)
    assert "m" in message
    assert "NoSuchConnection" in message
    assert "TYPE_CHECKING" in message
    assert "Injected[Any]" in message


def test_parameter_marked_both_injected_and_described_is_an_error() -> None:
    def m(x: Injected[Annotated[str, Field(description="d")]]) -> None: ...

    with pytest.raises(TypeError, match="x") as excinfo:
        _split_parameters(m)

    assert "Injected" in str(excinfo.value)


def test_split_parameters_merges_field_constraints() -> None:
    def m(
        value: Annotated[int, Field(gt=0), Field(description="Positive.")],
    ) -> None: ...

    fields, _ = _split_parameters(m)

    field_info = fields["value"][1]
    assert field_info.description == "Positive."
    # Verify that the gt=0 constraint is in the metadata
    assert len(field_info.metadata) > 0
    assert any(str(m).startswith("Gt") for m in field_info.metadata)


def _as_measure(obj: Any) -> Measure:
    """Narrow as_measure()'s result for tests that require it to succeed."""
    record = as_measure(obj)
    assert record is not None
    return record


def _count_measure() -> Measure:
    """The running example, matching count_measure_tool() in the R suite."""

    @measure(description="Count of orders.")
    def order_count(
        region: Annotated[
            Literal["EMEA", "AMER"], Field(description="The sales region.")
        ],
        revenue_under: Annotated[float, Field(description="Cap.")] = 0.0,
    ) -> int:
        return 1

    return _as_measure(order_count)


def test_measure_defaults_name_and_title_from_the_function() -> None:
    @measure(description="Count of orders.")
    def order_count() -> int:
        return 1

    m = as_measure(order_count)
    assert m is not None
    assert m.name == "order_count"
    assert m.title == "order count"
    assert m.description == "Count of orders."


def test_measure_leaves_the_function_callable() -> None:
    @measure(description="Count of orders.")
    def order_count() -> int:
        return 7

    assert order_count() == 7


def test_measure_takes_its_description_from_the_docstring() -> None:
    @measure()
    def order_count() -> int:
        """Count of orders."""
        return 1

    assert _as_measure(order_count).description == "Count of orders."


def test_measure_prefers_an_explicit_description_over_the_docstring() -> None:
    @measure(description="Explicit.")
    def order_count() -> int:
        """Docstring."""
        return 1

    assert _as_measure(order_count).description == "Explicit."


def test_measure_without_any_description_is_an_error() -> None:
    with pytest.raises(ValueError, match="order_count"):

        @measure()
        def order_count() -> int:
            return 1


def test_measure_accepts_an_explicit_name_and_title() -> None:
    @measure(description="d", name="orders", title="Orders placed")
    def order_count() -> int:
        return 1

    m = _as_measure(order_count)
    assert m.name == "orders"
    assert m.title == "Orders placed"


def test_measure_records_provenance_links() -> None:
    @measure(description="d", provenance=["https://example.com/spec"])
    def order_count() -> int:
        return 1

    assert _as_measure(order_count).provenance == ("https://example.com/spec",)


def test_measure_hides_injected_parameters_from_the_schema() -> None:
    @measure(description="Revenue for a region.")
    def region_revenue(
        region: Annotated[str, Field(description="The sales region.")],
        warehouse: Injected[Any],
    ) -> int:
        return 0

    m = _as_measure(region_revenue)
    assert list(m.params.model_fields) == ["region"]
    assert m.injected == ("warehouse",)


def test_as_measure_returns_none_for_a_plain_function() -> None:
    def helper() -> int:
        return 1

    assert as_measure(helper) is None


def test_as_measure_passes_a_measure_through() -> None:
    m = _count_measure()
    assert as_measure(m) is m


def test_validate_args_coerces_valid_arguments() -> None:
    args = _count_measure().validate_args({"region": "EMEA", "revenue_under": "1000"})

    assert args == {"region": "EMEA", "revenue_under": 1000.0}


def test_validate_args_rejects_out_of_vocabulary_enum_values() -> None:
    with pytest.raises(ValidationError, match="LATAM"):
        _count_measure().validate_args({"region": "LATAM"})


def test_validate_args_rejects_unknown_arguments() -> None:
    with pytest.raises(ValidationError, match="nope"):
        _count_measure().validate_args({"region": "EMEA", "nope": 1})


def test_validate_args_enforces_required_arguments() -> None:
    with pytest.raises(ValidationError, match="region"):
        _count_measure().validate_args({})


def test_validate_args_omits_arguments_the_model_did_not_send() -> None:
    args = _count_measure().validate_args({"region": "EMEA"})

    assert args == {"region": "EMEA"}


def test_validate_args_treats_none_as_no_arguments() -> None:
    @measure(description="d")
    def no_args() -> int:
        return 1

    assert _as_measure(no_args).validate_args(None) == {}


def test_measure_is_frozen() -> None:
    m = _count_measure()
    with pytest.raises(FrozenInstanceError):
        m.name = "other"  # type: ignore[misc]


SCHEMA_CASES: list[dict[str, Any]] = load_shared_fixture("measure-schema")[
    "measure_schema_text"
]["cases"]

_SCALARS: dict[str, Any] = {
    "string": str,
    "integer": int,
    "number": float,
    "boolean": bool,
}


def _fixture_annotation(spec: dict[str, Any]) -> Any:
    kind = spec["type"]
    if kind == "enum":
        return Literal[tuple(spec["values"])]  # type: ignore[misc]
    if kind == "array":
        return list[_fixture_annotation(spec["items"])]
    return _SCALARS[kind]


def _fixture_measure(spec: dict[str, Any]) -> Measure:
    """Build a measure from a fixture spec and decorate it with the production
    @measure, so this runner enters through the same front door as
    test-measures.R's runner enters measure().

    A real function is generated because @measure inspects a signature, not a
    spec; each described argument keeps its position, required arguments and
    injected arguments come first (Python requires that), and defaulted
    arguments follow. A case declaring a required argument after an optional
    one cannot be built without reordering, which would render a different
    argument order than the R runner, so it is rejected rather than built.
    """
    optional_seen = False
    for argument in spec["arguments"]:
        if argument["required"] and optional_seen:
            raise ValueError(
                f"Fixture case {spec['name']!r} declares required argument "
                f"{argument['name']!r} after an optional one; Python requires "
                "defaulted parameters last, so this runner cannot preserve "
                "declaration order for that case."
            )
        optional_seen = optional_seen or not argument["required"]

    namespace: dict[str, Any] = {}
    required_params: list[str] = []
    optional_params: list[str] = []

    for argument in spec["arguments"]:
        type_name = f"_{argument['name']}_type"
        namespace[type_name] = Annotated[
            _fixture_annotation(argument), Field(description=argument["description"])
        ]
        if argument["required"]:
            required_params.append(f"{argument['name']}: {type_name}")
        else:
            default_name = f"_{argument['name']}_default"
            namespace[default_name] = argument["default"]
            optional_params.append(f"{argument['name']}: {type_name} = {default_name}")

    injected_params: list[str] = []
    for injected_name in spec["injected"]:
        type_name = f"_{injected_name}_type"
        namespace[type_name] = Injected[Any]
        injected_params.append(f"{injected_name}: {type_name}")

    params = ", ".join(required_params + injected_params + optional_params)
    exec(f"def {spec['name']}({params}) -> None: ...", namespace)  # noqa: S102
    func = namespace[spec["name"]]

    decorated = measure(description=spec["description"], name=spec["name"])(func)
    return _as_measure(decorated)


def test_schema_fixture_is_not_empty() -> None:
    assert SCHEMA_CASES


@pytest.mark.parametrize("case", SCHEMA_CASES, ids=lambda case: case["name"])
def test_measure_schema_text_matches_the_shared_fixture(case: dict[str, Any]) -> None:
    rendered = measure_schema_text(
        _fixture_measure(case["measure"]),
        source_names=case["source_names"],
        heading=case.get("heading"),
    )

    assert rendered == case["expected"]


def test_measure_schema_text_names_a_bare_enum_arguments_vocabulary() -> None:
    """pydantic schemas a bare enum.Enum as a `$ref` into `$defs`, not inline."""

    class Region(str, enum.Enum):
        EMEA = "EMEA"
        AMER = "AMER"

    @measure(description="Orders by region.")
    def regional_orders(
        region: Annotated[Region, Field(description="The sales region.")],
    ) -> int:
        return 1

    rendered = measure_schema_text(_as_measure(regional_orders))

    assert "region (one of {EMEA, AMER}, required) The sales region." in rendered


def test_measure_schema_text_names_a_bare_enum_arrays_vocabulary() -> None:
    class Region(str, enum.Enum):
        EMEA = "EMEA"
        AMER = "AMER"

    @measure(description="Orders by region.")
    def regional_orders(
        regions: Annotated[list[Region], Field(description="Regions to include.")],
    ) -> int:
        return 1

    rendered = measure_schema_text(_as_measure(regional_orders))

    assert "regions (array of {EMEA, AMER}, required) Regions to include." in rendered


def test_measure_schema_text_names_a_nullable_bare_enum_arguments_vocabulary() -> None:
    """pydantic wraps a nullable field in `anyOf` with a null branch."""

    class Region(str, enum.Enum):
        EMEA = "EMEA"
        AMER = "AMER"

    @measure(description="Orders by region.")
    def regional_orders(
        region: Annotated[
            Region | None, Field(description="Bare enum, nullable.")
        ] = None,
    ) -> int:
        return 1

    rendered = measure_schema_text(_as_measure(regional_orders))

    assert "region (one of {EMEA, AMER}, optional) Bare enum, nullable." in rendered


def test_measure_schema_text_names_a_nullable_literal_arguments_vocabulary() -> None:
    @measure(description="Orders by region.")
    def regional_orders(
        region: Annotated[
            Literal["EMEA", "AMER"] | None, Field(description="Literal, nullable.")
        ] = None,
    ) -> int:
        return 1

    rendered = measure_schema_text(_as_measure(regional_orders))

    assert "region (one of {EMEA, AMER}, optional) Literal, nullable." in rendered


def test_measure_schema_text_names_a_nullable_enum_arrays_vocabulary() -> None:
    class Region(str, enum.Enum):
        EMEA = "EMEA"
        AMER = "AMER"

    @measure(description="Orders by region.")
    def regional_orders(
        regions: Annotated[
            list[Region] | None, Field(description="Enum array, nullable.")
        ] = None,
    ) -> int:
        return 1

    rendered = measure_schema_text(_as_measure(regional_orders))

    assert "regions (array of {EMEA, AMER}, optional) Enum array, nullable." in rendered


def test_semantic_layer_keys_measures_by_name() -> None:
    @measure(description="Count of orders.")
    def order_count() -> int:
        return 1

    layer = semantic_layer(order_count)

    assert list(layer.measures) == ["order_count"]
    assert layer.measures["order_count"].description == "Count of orders."


def test_semantic_layer_accepts_a_list_of_measures() -> None:
    @measure(description="Count of orders.")
    def order_count() -> int:
        return 1

    @measure(description="Total revenue.")
    def total_revenue() -> int:
        return 2

    layer = semantic_layer([order_count, total_revenue])

    assert list(layer.measures) == ["order_count", "total_revenue"]


def test_semantic_layer_accepts_a_bare_measure_record() -> None:
    layer = semantic_layer(_count_measure())

    assert list(layer.measures) == ["order_count"]


def test_semantic_layer_is_empty_with_no_arguments() -> None:
    layer = semantic_layer()

    assert len(layer) == 0
    assert layer.measures == {}


def test_semantic_layer_rejects_a_non_measure() -> None:
    with pytest.raises(TypeError, match="2026"):
        semantic_layer(2026)


def test_semantic_layer_rejects_an_undecorated_function() -> None:
    def helper() -> int:
        return 1

    with pytest.raises(TypeError, match="helper"):
        semantic_layer(helper)


def test_semantic_layer_rejects_duplicate_names() -> None:
    # Two *different* measures that share a name: each factory call decorates
    # a fresh function, so the records are distinct objects.
    def make() -> Measure:
        @measure(description="Count of orders.", name="order_count")
        def calc() -> int:
            return 1

        return _as_measure(calc)

    with pytest.raises(ValueError, match="order_count"):
        semantic_layer(make(), make())


def test_semantic_layer_accepts_the_same_measure_twice() -> None:
    @measure(description="Count of orders.")
    def order_count() -> int:
        return 1

    layer = semantic_layer(order_count, order_count)

    assert list(layer.measures) == ["order_count"]


def test_semantic_layer_harvests_inline_measure_source() -> None:
    @measure(description="Count of orders.")
    def order_count() -> int:
        return 1

    layer = semantic_layer(order_count)

    assert "def order_count()" in layer.source_text["order_count"]


def test_collect_nested_list_keeps_first_definition_wins() -> None:
    # Both functions are named `calc`, so they collide in `source_text`
    # (keyed by Python name) without colliding in `measures` (keyed by the
    # distinct `name=` given to each).
    def make_first() -> Any:
        @measure(description="First.", name="first")
        def calc() -> int:
            return 1

        return as_measure(calc)

    def make_second() -> Any:
        @measure(description="Second.", name="second")
        def calc() -> int:
            return 2

        return as_measure(calc)

    first, second = make_first(), make_second()

    top_level = semantic_layer(first, second)
    nested = semantic_layer([first, second])

    assert nested.source_text["calc"] == top_level.source_text["calc"]
    assert "return 1" in nested.source_text["calc"]


def test_semantic_layer_reports_its_size() -> None:
    layer = semantic_layer(_count_measure())

    assert len(layer) == 1
    assert "1 measure" in repr(layer)


MEASURE_FILES = Path(__file__).parent / "measure_sources"


def test_semantic_layer_reads_a_file_path() -> None:
    layer = semantic_layer(MEASURE_FILES / "orders.py")

    assert list(layer.measures) == ["order_count"]


def test_semantic_layer_accepts_a_string_path() -> None:
    layer = semantic_layer(str(MEASURE_FILES / "orders.py"))

    assert list(layer.measures) == ["order_count"]


def test_semantic_layer_reads_a_directory_without_recursing() -> None:
    layer = semantic_layer(MEASURE_FILES)

    assert list(layer.measures) == ["order_count", "total_revenue"]


def test_semantic_layer_reads_a_module_object() -> None:
    module = importlib.import_module("commons._measures")

    layer = semantic_layer(module)

    assert layer.measures == {}


def test_semantic_layer_mixes_files_and_inline_measures() -> None:
    @measure(description="Inline.")
    def inline_measure() -> int:
        return 1

    layer = semantic_layer(MEASURE_FILES / "orders.py", inline_measure)

    assert list(layer.measures) == ["order_count", "inline_measure"]


def test_semantic_layer_harvests_helper_source_alongside_measures() -> None:
    layer = semantic_layer(MEASURE_FILES / "orders.py")

    assert set(layer.source_text) >= {"double", "order_count"}
    assert "x * 2" in layer.source_text["double"]
    assert "@measure(" in layer.source_text["order_count"]


def test_harvested_source_excludes_imported_names() -> None:
    layer = semantic_layer(MEASURE_FILES / "orders.py")

    assert "measure" not in layer.source_text
    assert "Field" not in layer.source_text


def test_only_text_leaves_the_semantic_layer() -> None:
    layer = semantic_layer(MEASURE_FILES / "orders.py")

    assert all(isinstance(text, str) for text in layer.source_text.values())


def test_same_file_name_in_two_directories_both_load() -> None:
    layer = semantic_layer(
        MEASURE_FILES / "orders.py", MEASURE_FILES / "nested" / "orders.py"
    )

    assert list(layer.measures) == ["order_count", "nested_order_count"]


def test_missing_path_is_an_error() -> None:
    with pytest.raises(ValueError, match="not a measure"):
        semantic_layer("not a measure")


def test_missing_path_error_names_the_path() -> None:
    with pytest.raises(ValueError, match="nowhere.py"):
        semantic_layer(MEASURE_FILES / "nowhere.py")


def test_directory_scan_keeps_the_first_files_helper_source() -> None:
    # a_file.py sorts before b_file.py; both define a `helper` function, and
    # the first one scanned must win.
    layer = semantic_layer(MEASURE_FILES / "duplicate_helpers")

    assert list(layer.measures) == ["measure_a", "measure_b"]
    assert "return 1" in layer.source_text["helper"]
    assert "return 2" not in layer.source_text["helper"]


def test_failed_import_does_not_dirty_sys_modules() -> None:
    path = MEASURE_FILES / "broken" / "broken_import.py"

    with pytest.raises(RuntimeError, match="boom"):
        semantic_layer(path)

    assert not any("broken_import" in name for name in sys.modules)


def test_failed_import_that_deletes_its_own_module_entry_still_raises() -> None:
    # If the module removes its sys.modules entry before raising, cleanup
    # must not turn the real error into a KeyError.
    path = MEASURE_FILES / "broken" / "self_removing_import.py"

    with pytest.raises(RuntimeError, match="boom"):
        semantic_layer(path)


def test_measure_file_imports_a_sibling_file_directly() -> None:
    layer = semantic_layer(MEASURE_FILES / "sibling_imports" / "uses_helper.py")

    assert list(layer.measures) == ["doubled_count"]
    assert layer.measures["doubled_count"].func() == 42


def test_dotted_filename_does_not_get_a_dotted_module_name(
    tmp_path: Path,
) -> None:
    # path.stem for "sales.q3.py" is "sales.q3": left unsanitized, the
    # generated module name would still be dotted, giving the loaded file a
    # non-empty __package__ and undoing the single-segment name fix.
    dotted = tmp_path / "sales.q3.py"
    dotted.write_text("from ..nope import thing\n")

    with pytest.raises(
        ImportError, match="attempted relative import with no known parent package"
    ):
        semantic_layer(dotted)


def test_load_module_from_path_reuses_an_unchanged_file(tmp_path: Path) -> None:
    source = tmp_path / "m.py"
    source.write_text("VALUE = 1\n")

    first = _load_module_from_path(source)
    second = _load_module_from_path(source)

    assert first is second


def test_load_module_from_path_reloads_an_edited_file(tmp_path: Path) -> None:
    # An edit within the same whole second that leaves the file's size
    # unchanged ("VALUE = 1" -> "VALUE = 2"): the case SourceFileLoader's own
    # bytecode cache cannot detect, since it validates by whole-second mtime
    # and size, coarser than the nanosecond mtime our cache compares
    # against. Both mtimes are pinned explicitly, not read off the file
    # naturally and nudged, so the test cannot straddle a real second
    # boundary and become flaky.
    source = tmp_path / "m.py"
    base_ns = 1_700_000_000 * 1_000_000_000
    source.write_text("VALUE = 1\n")
    os.utime(source, ns=(base_ns, base_ns))
    first = _load_module_from_path(source)

    source.write_text("VALUE = 2\n")
    os.utime(source, ns=(base_ns, base_ns + 500_000_000))

    second = _load_module_from_path(source)

    assert second is not first
    assert second.VALUE == 2


def test_load_module_from_path_invalidates_a_pre_existing_bytecode_cache(
    tmp_path: Path,
) -> None:
    # A stale, timestamp-valid .pyc can predate this process's own record of
    # having loaded the file at all -- written by an earlier process, then
    # the file edited same-second, same-size before this process's first
    # load of it. Simulated here without spawning a real second process: load
    # once to produce the .pyc via SourceFileLoader, edit the file, then
    # clear this process's own sys.modules and _load_mtimes entries for it
    # so the next load has no in-memory record either -- indistinguishable,
    # from _load_module_from_path's point of view, from a fresh process's
    # first load of an already-edited file.
    source = tmp_path / "m.py"
    base_ns = 1_700_000_000 * 1_000_000_000
    source.write_text("VALUE = 1\n")
    os.utime(source, ns=(base_ns, base_ns))
    first = _load_module_from_path(source)
    name = first.__name__

    source.write_text("VALUE = 2\n")
    os.utime(source, ns=(base_ns, base_ns + 500_000_000))
    sys.modules.pop(name, None)
    _load_mtimes.pop(name, None)

    second = _load_module_from_path(source)

    assert second.VALUE == 2


def test_load_module_from_path_ignores_a_same_named_module_from_elsewhere(
    tmp_path: Path,
) -> None:
    # Exercises the identity check directly rather than forcing a genuine
    # 32-bit digest collision between two distinct filenames: plant a module
    # under the exact sys.modules name this path would use, with the same
    # recorded mtime but a __file__ pointing elsewhere, and confirm the real
    # file is (re-)loaded rather than the stand-in being returned.
    source = tmp_path / "m.py"
    source.write_text("VALUE = 1\n")
    real = _load_module_from_path(source)
    name = real.__name__

    imposter = ModuleType(name)
    imposter.__file__ = str(tmp_path / "elsewhere.py")
    sys.modules[name] = imposter

    loaded = _load_module_from_path(source)

    assert loaded is not imposter
    assert loaded.VALUE == 1


def test_sys_path_is_restored_after_a_successful_load() -> None:
    directory = str(MEASURE_FILES / "sibling_imports")

    semantic_layer(MEASURE_FILES / "sibling_imports" / "uses_helper.py")

    assert directory not in sys.path


def test_sys_path_is_restored_after_a_failing_load() -> None:
    directory = str(MEASURE_FILES / "broken")

    with pytest.raises(RuntimeError, match="boom"):
        semantic_layer(MEASURE_FILES / "broken" / "broken_import.py")

    assert directory not in sys.path


def test_stdlib_name_collision_is_a_construction_error() -> None:
    path = MEASURE_FILES / "stdlib_collision" / "json.py"

    with pytest.raises(ValueError, match="json.py") as excinfo:
        semantic_layer(path)

    assert "standard library" in str(excinfo.value)


def test_same_named_helper_in_two_directories_is_a_construction_error() -> None:
    try:
        semantic_layer(MEASURE_FILES / "collision_a" / "uses_shared.py")

        with pytest.raises(ValueError, match="shared_lib"):
            semantic_layer(MEASURE_FILES / "collision_b" / "shared_lib.py")
    finally:
        sys.modules.pop("shared_lib", None)


def test_installed_but_unimported_module_is_a_construction_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A directory on sys.path stands in for an installed package: find_spec()
    # can resolve it without anything having imported it yet.
    site_packages = tmp_path / "site-packages"
    site_packages.mkdir()
    (site_packages / "certainly_not_a_measure.py").write_text("VALUE = 1\n")
    monkeypatch.syspath_prepend(str(site_packages))
    sys.modules.pop("certainly_not_a_measure", None)

    measures_dir = tmp_path / "measures"
    measures_dir.mkdir()
    colliding = measures_dir / "certainly_not_a_measure.py"
    colliding.write_text(
        "from commons._measures import measure\n\n\n"
        "@measure(description='d')\n"
        "def m() -> int:\n"
        "    return 1\n"
    )

    with pytest.raises(ValueError, match="certainly_not_a_measure.py") as excinfo:
        semantic_layer(colliding)

    message = str(excinfo.value)
    assert "certainly_not_a_measure" in message
    assert "already-importable" in message


def test_a_same_named_module_without_a_spec_is_a_construction_error(
    tmp_path: Path,
) -> None:
    # A module planted straight into sys.modules (a stub or test double,
    # say) has no __spec__ for find_spec() to return, so the collision
    # check falls back to looking in sys.modules itself.
    (tmp_path / "planted.py").write_text(
        "from commons._measures import measure\n\n\n"
        "@measure(description='d')\n"
        "def m() -> int:\n"
        "    return 1\n"
    )
    sys.modules["planted"] = ModuleType("planted")
    try:
        with pytest.raises(ValueError, match="already imported from"):
            semantic_layer(tmp_path / "planted.py")
    finally:
        sys.modules.pop("planted", None)


def _region_revenue(default: Any = inspect.Parameter.empty) -> Measure:
    if default is inspect.Parameter.empty:

        @measure(description="Revenue for a region.")
        def region_revenue(warehouse: Injected[Any]) -> int:
            return 0
    else:

        @measure(description="Revenue for a region.")
        def region_revenue(warehouse: Injected[Any] = default) -> int:
            return 0

    return _as_measure(region_revenue)


def test_resolve_injections_binds_a_matching_source() -> None:
    connection = object()
    layer = semantic_layer(_region_revenue())

    resolved = resolve_injections(layer.measures, {"warehouse": connection})

    assert resolved == {"region_revenue": {"warehouse": connection}}


def test_resolve_injections_prefers_a_source_over_a_default() -> None:
    connection = object()
    layer = semantic_layer(_region_revenue(default="fallback"))

    resolved = resolve_injections(layer.measures, {"warehouse": connection})

    assert resolved["region_revenue"]["warehouse"] is connection


def test_resolve_injections_leaves_an_unmatched_default_alone() -> None:
    layer = semantic_layer(_region_revenue(default="fallback"))

    resolved = resolve_injections(layer.measures, {"finance": object()})

    assert resolved == {"region_revenue": {}}


def test_resolve_injections_errors_on_an_unmatched_argument() -> None:
    layer = semantic_layer(_region_revenue())

    with pytest.raises(ValueError) as excinfo:
        resolve_injections(layer.measures, {"finance": object()})

    message = str(excinfo.value)
    assert "region_revenue" in message
    assert "warehouse" in message
    assert "finance" in message


def test_resolve_injections_says_when_there_are_no_named_sources() -> None:
    layer = semantic_layer(_region_revenue())

    with pytest.raises(ValueError, match="no named data sources"):
        resolve_injections(layer.measures, {})


def test_resolve_injections_lists_every_unmatched_argument_at_once() -> None:
    @measure(description="Joins two warehouses.")
    def joined(left: Injected[Any], right: Injected[Any]) -> int:
        return 0

    layer = semantic_layer(joined)

    with pytest.raises(ValueError) as excinfo:
        resolve_injections(layer.measures, {})

    message = str(excinfo.value)
    assert "left" in message
    assert "right" in message


def test_resolve_injections_returns_an_entry_for_every_measure() -> None:
    layer = semantic_layer(_count_measure())

    assert resolve_injections(layer.measures, {}) == {"order_count": {}}


def test_public_api_exposes_the_semantic_layer() -> None:
    import commons

    assert set(commons.__all__) >= {
        "Injected",
        "Measure",
        "SemanticLayer",
        "measure",
        "semantic_layer",
    }
    assert commons.measure is measure
    assert commons.semantic_layer is semantic_layer


def test_semantic_layer_reenters_during_a_measure_files_import() -> None:
    # A non-reentrant lock deadlocks here rather than raising, so this runs
    # on a daemon thread with a timeout: a regression fails the test instead
    # of hanging the suite.
    result: dict[str, Any] = {}

    def target() -> None:
        result["layer"] = semantic_layer(
            MEASURE_FILES / "reentrant" / "composes_a_sibling.py"
        )

    thread = threading.Thread(target=target, daemon=True)
    thread.start()
    thread.join(timeout=5)

    assert not thread.is_alive(), (
        "semantic_layer() deadlocked re-entering during a measure file's import"
    )

    outer_layer = result["layer"]
    assert list(outer_layer.measures) == ["outer_measure"]

    module_name = outer_layer.measures["outer_measure"].func.__module__
    fixture_module = sys.modules[module_name]
    assert list(fixture_module.NESTED_LAYER.measures) == ["nested_order_count"]


def test_semantic_layer_supports_membership_and_iteration() -> None:
    layer = semantic_layer(_count_measure())

    assert "order_count" in layer
    assert "other" not in layer
    assert list(layer) == ["order_count"]


def test_semantic_layer_mappings_are_read_only() -> None:
    # Only text and frozen records leave the layer; a plain dict here would
    # let a caller mutate the layer after construction.
    layer = semantic_layer(_count_measure())

    with pytest.raises(TypeError):
        layer.measures["other"] = _count_measure()  # type: ignore[index]
    with pytest.raises(TypeError):
        layer.source_text["other"] = "def other(): ..."  # type: ignore[index]


def test_a_directory_and_a_file_inside_it_overlap_without_error() -> None:
    layer = semantic_layer(
        MEASURE_FILES / "sibling_imports",
        MEASURE_FILES / "sibling_imports" / "uses_helper.py",
    )

    assert list(layer.measures) == ["doubled_count"]


def test_a_module_level_alias_is_collected_once() -> None:
    layer = semantic_layer(MEASURE_FILES / "aliased" / "aliased.py")

    assert list(layer.measures) == ["aliased_measure"]


def test_a_module_level_alias_shares_one_source_text_entry() -> None:
    # Keyed by function name, not binding: the alias is the same function.
    layer = semantic_layer(MEASURE_FILES / "aliased" / "aliased.py")

    assert set(layer.source_text) == {"aliased_measure"}


def test_distinct_measures_from_two_files_sharing_a_name_are_an_error() -> None:
    with pytest.raises(ValueError, match="dup"):
        semantic_layer(
            MEASURE_FILES / "duplicate_measures" / "a_measure.py",
            MEASURE_FILES / "duplicate_measures" / "b_measure.py",
        )


def test_a_non_python_file_path_is_an_error(tmp_path: Path) -> None:
    notes = tmp_path / "notes.txt"
    notes.write_text("not python\n")

    with pytest.raises(ValueError, match="not a Python file"):
        semantic_layer(notes)


def test_a_compiled_bytecode_path_is_an_error(tmp_path: Path) -> None:
    # spec_from_file_location gives a .pyc a real loader, so without an
    # explicit suffix check this path would execute as bytecode.
    source = tmp_path / "m.py"
    source.write_text("VALUE = 1\n")
    compiled = tmp_path / "m.pyc"
    py_compile.compile(str(source), cfile=str(compiled))

    with pytest.raises(ValueError, match="not a Python file"):
        semantic_layer(compiled)


def test_a_non_python_file_is_rejected_before_the_directory_check(
    tmp_path: Path,
) -> None:
    # The requested file's error must win over a sibling's collision: the
    # sibling is only checked because its directory would go on sys.path,
    # which never happens for a file that is not Python at all.
    (tmp_path / "json.py").write_text("VALUE = 1\n")
    notes = tmp_path / "notes.txt"
    notes.write_text("not python\n")

    with pytest.raises(ValueError, match="not a Python file"):
        semantic_layer(notes)


def test_a_directorys_init_py_is_never_imported() -> None:
    # has_init/__init__.py raises if it is ever executed.
    layer = semantic_layer(MEASURE_FILES / "has_init")

    assert list(layer.measures) == ["has_init_measure"]


def test_source_text_falls_back_when_source_is_unavailable() -> None:
    # A function built by exec has no file for inspect.getsource to read.
    namespace: dict[str, Any] = {}
    exec("def ghost() -> int:\n    return 1\n", namespace)  # noqa: S102
    record = _as_measure(measure(description="d")(namespace["ghost"]))

    layer = semantic_layer(record)

    assert layer.source_text["ghost"] == "# source unavailable for ghost"


def test_a_directory_already_on_sys_path_is_left_in_place(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "m.py"
    source.write_text("VALUE = 1\n")
    monkeypatch.syspath_prepend(str(tmp_path))

    module = _load_module_from_path(source)

    assert module.VALUE == 1
    assert str(tmp_path) in sys.path


def test_a_dotted_filename_loads_despite_the_collision_check() -> None:
    # "email.mime" resolves to a real stdlib submodule; the check must skip
    # a stem that cannot be imported as a single segment rather than report
    # a phantom shadowing (or import the parent package as a side effect).
    layer = semantic_layer(MEASURE_FILES / "dotted" / "email.mime.py")

    assert list(layer.measures) == ["dotted_measure"]


def test_a_subdirectory_shadowing_the_standard_library_is_an_error() -> None:
    # pkg_collision/json/ is importable as a namespace package once its
    # parent is on sys.path, exactly like a json.py sibling.
    with pytest.raises(ValueError, match="standard library"):
        semantic_layer(MEASURE_FILES / "pkg_collision" / "orders.py")


def test_a_module_level_bare_record_is_harvested() -> None:
    layer = semantic_layer(MEASURE_FILES / "bare_record" / "total.py")

    assert list(layer.measures) == ["grand_total"]
    assert layer.measures["grand_total"].func() == 1
    assert "def total" in layer.source_text["total"]


def test_an_imported_bare_record_is_not_harvested() -> None:
    # A bare record re-exported by another module belongs to the module
    # that defined its function, same as an imported function.
    module = _load_module_from_path(MEASURE_FILES / "bare_record" / "total.py")

    reexporter = ModuleType("reexporter")
    reexporter.__dict__["grand_total"] = module.grand_total

    measures, sources = _from_module(reexporter)

    assert measures == []
    assert sources == {}

"""The semantic layer: measures, their schemas, and injected arguments."""

from dataclasses import FrozenInstanceError
from typing import Annotated, Any, Literal, get_args, get_origin

import pytest
from pydantic import Field, ValidationError

from commons._measures import (
    INJECTED,
    Injected,
    Measure,
    _split_parameters,
    as_measure,
    measure,
)


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

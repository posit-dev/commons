"""The semantic layer: measures, their schemas, and injected arguments."""

from typing import Annotated, Any, get_args, get_origin

import pytest
from pydantic import Field

from commons._measures import INJECTED, Injected, _split_parameters


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

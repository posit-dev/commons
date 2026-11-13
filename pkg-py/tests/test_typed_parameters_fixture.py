"""The typed-parameter contract both packages consume.

The R suite runs the same cases from the same file. See tests/shared/README.md.
"""

from typing import Any

import pytest

from commons._semantic_models import TypedParameter, parameter_type, validate_arguments

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("typed-parameters")


def cases(section: str) -> list[dict[str, Any]]:
    # An empty section would collect zero cases and the runner would pass.
    found = SPEC[section]["cases"]
    assert found, section
    return found


@pytest.mark.parametrize(
    "case", cases("declared_types"), ids=lambda c: repr(c["declared"])
)
def test_declared_type(case: dict[str, Any]) -> None:
    assert parameter_type(case["declared"]) == case["type"]


@pytest.mark.parametrize(
    "case", cases("values"), ids=lambda c: f"{c['type']}-{c['value']!r}"
)
def test_value(case: dict[str, Any]) -> None:
    parameter = TypedParameter(
        name="x", type=case["type"], description=None, default=None, has_default=False
    )
    supplied = {"x": case["value"]}
    if case["valid"]:
        assert validate_arguments({"x": parameter}, supplied) == supplied
        return
    with pytest.raises(ValueError) as raised:
        validate_arguments({"x": parameter}, supplied)
    reason = "missing" if "non-missing" in str(raised.value) else "type"
    assert reason == case["error"]

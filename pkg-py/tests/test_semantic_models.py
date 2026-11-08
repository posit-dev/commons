import pytest

from commons._data_source import TableId
from commons._semantic_models import (
    SemanticModel,
    SemanticStub,
    UnsupportedSemanticParameter,
    parameters_from_spec,
    spec_entries,
    validate_arguments,
)


def test_parameters_from_spec_reads_defaults():
    params = parameters_from_spec(
        [
            {"name": "fy", "data_type": "NUMBER", "default_value": "2024"},
            {"name": "on", "data_type": "BOOLEAN", "default_value": "TRUE"},
            {"name": "who", "data_type": "VARCHAR"},
        ],
        "Snowflake",
    )
    assert params["fy"].default == 2024.0
    assert params["fy"].has_default is True
    assert params["on"].default is True
    assert params["who"].has_default is False


def test_spec_entries_accepts_mapping():
    entries = spec_entries({"fy": {"data_type": "NUMBER"}})
    assert entries == [{"data_type": "NUMBER", "name": "fy"}]
    assert spec_entries([]) == []


def test_unsupported_parameter_raises():
    with pytest.raises(UnsupportedSemanticParameter) as err:
        parameters_from_spec([{"name": "v", "data_type": "VARIANT"}], "Snowflake")
    assert "'VARIANT'" in str(err.value)


def _params():
    return parameters_from_spec(
        [
            {"name": "fy", "data_type": "NUMBER", "default_value": "2024"},
            {"name": "region", "data_type": "VARCHAR"},
            {"name": "since", "data_type": "DATE"},
        ],
        "Snowflake",
    )


def test_validate_arguments_rejects_unknown_and_missing():
    with pytest.raises(ValueError, match="Unexpected argument: 'x'"):
        validate_arguments(_params(), {"region": "a", "since": "2024-01-01", "x": 1})
    with pytest.raises(ValueError, match="Missing required argument: 'since'"):
        validate_arguments(_params(), {"region": "a"})
    with pytest.raises(ValueError, match="'fy' must be an integer value"):
        validate_arguments(_params(), {"region": "a", "since": "2024-01-01", "fy": 1.5})
    with pytest.raises(ValueError, match="'since' must be a date value"):
        validate_arguments(_params(), {"region": "a", "since": "2024-02-30"})
    with pytest.raises(ValueError, match="one non-missing value"):
        validate_arguments(_params(), {"region": None, "since": "2024-01-01"})


def test_validate_arguments_drops_unsupplied_defaults():
    out = validate_arguments(_params(), {"since": "2024-01-01", "region": "west"})
    assert out == {"region": "west", "since": "2024-01-01"}
    assert list(out) == ["region", "since"]


def test_model_context_deduplicates():
    model = SemanticModel(
        id=TableId("v"),
        name="v",
        backend="snowflake_semantic_view",
        first_touch=["a", "", "a", "b"],
        retrieval=["", "x", "x"],
    )
    assert model.first_touch == ["a", "b"]
    assert model.retrieval == ["x"]


def test_stub_kind():
    stub = SemanticStub(id=TableId("v"), backend="snowflake_semantic_view")
    assert stub.kind == "semantic_view"


def test_an_overflowing_default_is_unsupported():
    for data_type in ("DATE", "NUMBER"):
        with pytest.raises(UnsupportedSemanticParameter, match="has a default"):
            parameters_from_spec(
                [{"name": "d", "data_type": data_type, "default_value": 10**400}],
                "Snowflake",
            )


def test_huge_integer_argument_is_rejected_not_overflowed():
    params = parameters_from_spec([{"name": "n", "data_type": "FLOAT"}], "Snowflake")
    assert validate_arguments(params, {"n": 10**20}) == {"n": 10**20}
    with pytest.raises(ValueError, match="'n' must be a number value"):
        validate_arguments(params, {"n": 10**400})


def test_where_entry_must_be_an_object():
    from commons._semantic_models import where_conditions

    with pytest.raises(TypeError, match="as an object"):
        where_conditions(["invalid"], [], str, str)


def test_a_verified_query_hiding_dml_after_with_is_refused():
    # Stricter than the token check the shared fixture pins: the parse finds
    # the DELETE that a leading WITH would otherwise hide.
    from commons._semantic_models import new_trusted_calculation

    with pytest.raises(ValueError, match="exactly one read-only SELECT"):
        new_trusted_calculation(
            "sneaky", "Sneaky.", "WITH t AS (SELECT 1) DELETE FROM orders"
        )

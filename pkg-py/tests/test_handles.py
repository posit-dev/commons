"""Handles: tool results a later `run_python` call can reach by name."""

from typing import Any

import pytest

from commons._handles import HandleStore

from ._shared import load_shared_fixture

pd = pytest.importorskip("pandas")
pl = pytest.importorskip("polars")


def test_a_value_that_is_not_a_frame_is_registered_and_reachable():
    store = HandleStore()

    note = store.register(6)

    assert note == "Available to `run_python` as `r1`."
    assert store.ids() == ["r1"]
    assert store.get("r1") == 6


def test_nothing_is_registered_for_a_missing_value():
    store = HandleStore()

    assert store.register(None) is None
    assert store.ids() == []


def _register(store: HandleStore, value: object) -> str:
    note = store.register(value)
    assert note is not None
    return note


def test_a_frame_note_opens_with_its_shape():
    frame = pd.DataFrame({"region": ["north", "south"], "revenue": [1.5, 9.0]})

    note = _register(HandleStore(), frame)

    assert note.splitlines()[:2] == [
        "Available to `run_python` as `r1`.",
        "A data frame with 2 rows and 2 columns:",
    ]


def test_a_numeric_column_reports_its_range_and_missing_count():
    frame = pd.DataFrame({"revenue": [1.5, 9.0, None]})

    note = _register(HandleStore(), frame)

    dtype = frame["revenue"].dtype
    assert f"* revenue: {dtype} with range [1.5, 9.0], and 1 missing" in note


def test_a_string_column_reports_its_values_when_there_are_few():
    frame = pd.DataFrame({"region": ["north", "south", None]})

    note = _register(HandleStore(), frame)

    dtype = frame["region"].dtype
    assert (
        f'* region: {dtype} with 1 missing, and 2 unique values ("north", "south")'
        in note
    )


def test_a_boolean_column_reports_how_many_are_true():
    frame = pd.DataFrame({"flag": [True, False, True]})

    note = _register(HandleStore(), frame)

    dtype = frame["flag"].dtype
    assert f"* flag: {dtype} with 2 True, 1 False, and 0 missing" in note


def test_a_datetime_column_reports_a_readable_range():
    frame = pd.DataFrame({"when": pd.to_datetime(["2020-01-01", "2020-01-03"])})

    note = _register(HandleStore(), frame)

    assert "with range [2020-01-01, 2020-01-03]" in note


def test_a_polars_frame_is_described_in_the_same_terms():
    frame = pl.DataFrame(
        {"region": ["north", "south", None], "revenue": [1.5, 9.0, None]}
    )

    note = _register(HandleStore(), frame)

    assert "A data frame with 3 rows and 2 columns:" in note
    assert (
        '* region: String with 1 missing, and 2 unique values ("north", "south")'
        in note
    )
    assert "* revenue: Float64 with range [1.5, 9.0], and 1 missing" in note


def test_a_wide_frame_describes_fifty_columns_and_counts_the_rest():
    frame = pd.DataFrame({f"c{index}": [index] for index in range(55)})

    note = _register(HandleStore(), frame)

    assert "55 columns:" in note
    assert "* c49: " in note
    assert "* c50: " not in note
    assert "and 5 more columns" in note


def test_a_single_row_frame_reads_as_one_row():
    frame = pd.DataFrame({"revenue": [1.5]})

    note = _register(HandleStore(), frame)

    assert "A data frame with 1 row and 1 column:" in note


def test_a_long_frame_is_stored_truncated_and_says_so():
    frame = pd.DataFrame({"n": [1, 2, 3, 4]})
    store = HandleStore(max_rows=2)

    note = _register(store, frame)

    assert note.startswith(
        "Available to `run_python` as `r1`. Only the first 2 rows are stored.\n"
    )
    assert "A data frame with 2 rows and 1 column:" in note
    assert len(store.get("r1")) == 2


def test_shared_registration_cases():
    section = load_shared_fixture("handles")["registrations"]
    assert section["cases"]

    for case in section["cases"]:
        store = HandleStore(max_rows=section["max_rows"])
        for spec, expected in zip(case["values"], case["expected"], strict=True):
            note = store.register(_registered_value(spec))
            handle = expected["handle"]
            if handle is None:
                assert note is None, case["name"]
                continue
            assert note is not None, case["name"]
            opening = (
                section["note_template"]
                .replace("{tool}", "run_python")
                .replace("{handle}", handle)
            )
            first_line = note.splitlines()[0]
            assert first_line == opening + (
                f" {section['truncation_note']}" if expected["truncated"] else ""
            ), case["name"]
            if "stored_rows" in expected:
                assert len(store.get(handle)) == expected["stored_rows"], case["name"]
        assert store.ids() == [
            expected["handle"]
            for expected in case["expected"]
            if expected["handle"] is not None
        ], case["name"]


def _registered_value(spec: dict[str, Any]) -> Any:
    if spec["kind"] == "nothing":
        return None
    if spec["kind"] == "scalar":
        return 6
    return pd.DataFrame({"n": range(int(spec["rows"]))})


def test_a_column_with_no_values_left_has_no_range():
    frame = pd.DataFrame({"revenue": pd.Series([None, None], dtype="float64")})

    note = _register(HandleStore(), frame)

    assert "* revenue: float64 with 2 missing" in note
    assert "range" not in note


def test_one_of_a_kind_reads_as_one_unique_value():
    frame = pd.DataFrame({"region": ["north", "north"]})

    note = _register(HandleStore(), frame)

    assert '1 unique value ("north")' in note


def test_the_default_cap_is_ten_thousand_rows():
    frame = pd.DataFrame({"n": range(10_001)})
    store = HandleStore()

    note = _register(store, frame)

    assert "Only the first 10,000 rows are stored." in note
    assert len(store.get("r1")) == 10_000


def test_a_frame_with_duplicate_column_names_is_described():
    frame = pd.DataFrame([[1, 2], [3, 4]], columns=["a", "a"])

    note = _register(HandleStore(), frame)

    assert note.count("* a: ") == 2


def test_a_column_of_unhashable_values_reports_no_unique_count():
    frame = pd.DataFrame({"j": [[1, 2], [3, 4]]})

    note = _register(HandleStore(), frame)

    assert "* j: object with 0 missing" in note
    assert "unique" not in note


def test_a_value_that_only_has_columns_is_not_a_frame():
    class Table:
        columns = ("a", "b")

    store = HandleStore()

    note = store.register(Table())

    assert note == "Available to `run_python` as `r1`."
    assert store.ids() == ["r1"]


def test_an_unreadable_frame_is_stored_without_a_description():
    class OddFrame:
        columns = ("a",)

        def __len__(self) -> int:
            return 1

        def __getitem__(self, key: object) -> object:
            raise TypeError("cannot read columns")

    store = HandleStore()

    note = store.register(OddFrame())

    assert note == "Available to `run_python` as `r1`."
    assert store.ids() == ["r1"]


def test_many_unique_values_stay_a_count():
    frame = pd.DataFrame({"s": [f"value {index}" for index in range(11)]})

    note = _register(HandleStore(), frame)

    assert "11 unique values" in note
    assert '"value' not in note


def test_long_unique_values_stay_a_count():
    frame = pd.DataFrame({"s": ["x" * 150, "y" * 150]})

    note = _register(HandleStore(), frame)

    assert "2 unique values" in note
    assert "xxx" not in note


def test_a_unique_value_with_quotes_is_escaped():
    frame = pd.DataFrame({"s": ['say "hi"', "bye"]})

    note = _register(HandleStore(), frame)

    assert '"say \\"hi\\""' in note


def test_an_empty_frame_is_described():
    frame = pd.DataFrame({"n": pd.Series([], dtype="float64")})

    note = _register(HandleStore(), frame)

    assert "A data frame with 0 rows and 1 column:" in note
    assert "* n: float64 with 0 missing" in note


def test_a_frame_with_no_columns_is_described():
    note = _register(HandleStore(), pd.DataFrame())

    assert "A data frame with 0 rows and 0 columns:" in note


def test_a_boolean_column_that_is_all_true_reports_no_false():
    frame = pd.DataFrame({"flag": [True, True]})

    note = _register(HandleStore(), frame)

    dtype = frame["flag"].dtype
    assert f"* flag: {dtype} with 2 True, 0 False, and 0 missing" in note


def test_exactly_fifty_columns_are_all_described():
    frame = pd.DataFrame({f"c{index}": [index] for index in range(50)})

    note = _register(HandleStore(), frame)

    assert "* c49: " in note
    assert "more columns" not in note


def test_fifty_one_columns_counts_one_more():
    frame = pd.DataFrame({f"c{index}": [index] for index in range(51)})

    note = _register(HandleStore(), frame)

    assert "* c49: " in note
    assert "* c50: " not in note
    assert "and 1 more columns" in note

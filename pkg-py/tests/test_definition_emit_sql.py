"""Lowering to Snowflake and Databricks.

Unlike DuckDB, these targets have no upstream authority: the pinned data-dict
binary emits DuckDB and R targets only, so there is nothing to conform
against. See kata g0ax, which asks upstream for these targets so one
implementation serves both languages.

The expectations here therefore come from the shared fixture both suites
read, keyed to the same corpus dictionaries as every other definition
fixture.
"""

import pytest
import yaml

from commons._data_dictionary import DataDictionary
from commons._definitions import attach_compiled_definitions
from tests._shared import SHARED_DIR, load_shared_fixture

_DIALECT_TARGETS = {"snowflake": "SQL(snowflake)", "databricks": "SQL(databricks)"}
_EXPECTED_KEYS = {"code", "code_contains", "notes_contain", "composed_code"}


def compile_corpus(filename: str, dialect: str) -> dict:
    path = SHARED_DIR / "definition-export" / "valid" / filename
    dictionary = DataDictionary.model_validate(
        yaml.safe_load(path.read_text(encoding="utf-8"))
    )
    attach_compiled_definitions(dictionary, dialect, set(dictionary.tables))
    return {
        f"{table_name}::{record.name}": record
        for table_name, table in dictionary.tables.items()
        for record in table.compiled_definitions
    }


def test_the_warehouse_lowering_matches_the_shared_contract():
    """Every case in the fixture, for whichever targets it names.

    The fixture is hand-maintained because no binary can generate it, so the
    runner enumerates rather than hardcoding: a case added there is asserted
    here without touching this file.
    """
    fixture = load_shared_fixture("definition-warehouse-sql")["cases"]
    assert fixture, "the warehouse fixture is empty"
    checked = 0
    for filename, cases in fixture.items():
        compiled = {
            target: compile_corpus(filename, dialect)
            for dialect, target in _DIALECT_TARGETS.items()
        }
        for key, targets in cases.items():
            for target, expected in targets.items():
                unknown = set(expected) - _EXPECTED_KEYS
                assert not unknown, f"{filename} {key} {target}: {sorted(unknown)}"
                record = compiled[target][key]
                assert record.target == target, key
                # record.sql is the composed SQL either way: the uncomposed
                # per-target emission is not exposed (see _compile.py).
                if "code" in expected:
                    assert record.sql == expected["code"], f"{filename} {key} {target}"
                if "composed_code" in expected:
                    assert record.sql == expected["composed_code"], (
                        f"{filename} {key} {target}"
                    )
                for fragment in expected.get("code_contains", []):
                    assert fragment in record.sql, f"{filename} {key} {target}"
                for fragment in expected.get("notes_contain", []):
                    assert any(fragment in note for note in record.notes), (
                        f"{filename} {key} {target}"
                    )
                checked += 1
    assert checked >= 20


# --- refusals --------------------------------------------------------------


def test_a_dialect_commons_cannot_lower_is_still_refused():
    dictionary = DataDictionary.model_validate(
        {
            "tables": [
                {
                    "name": "t",
                    "columns": [{"name": "a", "type": "number"}],
                    "definitions": [{"name": "d", "expr": "a > 0"}],
                }
            ]
        }
    )
    with pytest.raises(ValueError, match="postgresql"):
        attach_compiled_definitions(dictionary, "postgresql", set(dictionary.tables))


def test_warehouse_refusals_match_the_shared_contract():
    """Constructs a target cannot express, and their accepted counterparts.

    A refusal is an error on the translation, which surfaces as construction
    failing when the source's own target is the one that cannot lower the
    definition.
    """
    unsupported = load_shared_fixture("definition-warehouse-sql")["unsupported"]
    assert unsupported, "the unsupported section is empty"
    checked = 0
    for case_name, case in unsupported.items():
        table = {"name": case["table"], "definitions": [case["definition"]]}
        if "columns" in case:
            table["columns"] = case["columns"]
        for target, expected in case["targets"].items():
            info = f"{case_name} {target}"
            unknown = set(expected) - {"code", "error_contains"}
            assert not unknown, f"{info}: {sorted(unknown)}"
            dictionary = DataDictionary.model_validate({"tables": [table]})
            dialect = target[len("SQL(") : -1]
            if "error_contains" in expected:
                with pytest.raises(ValueError) as excinfo:
                    attach_compiled_definitions(
                        dictionary, dialect, set(dictionary.tables)
                    )
                for fragment in expected["error_contains"]:
                    assert fragment in str(excinfo.value), info
            else:
                attach_compiled_definitions(dictionary, dialect, set(dictionary.tables))
                (record,) = dictionary.tables[case["table"]].compiled_definitions
                assert record.sql == expected["code"], info
            checked += 1
    assert checked >= 8


@pytest.mark.parametrize("dialect", ["snowflake", "databricks"])
def test_every_corpus_definition_lowers_for_both_warehouses(dialect: str):
    total = 0
    for filename in ["core.yaml", "functions.yaml", "language.yaml"]:
        records = compile_corpus(filename, dialect)
        assert records
        total += len(records)
    assert total == 42


@pytest.mark.parametrize(
    ("dialect", "expected"),
    [
        ("snowflake", '("amount" > 100) AND "amount" < 500'),
        ("databricks", "(`amount` > 100) AND `amount` < 500"),
    ],
)
def test_a_referenced_definition_is_inlined_for_each_dialect(
    dialect: str, expected: str
):
    """Composition has to know how the target quotes an identifier.

    The reference marker is emitted as a quoted identifier, so a composer that
    only recognises double quotes leaves Databricks SQL referring to a column
    named `__commons_definition_reference_001__`.
    """
    dictionary = DataDictionary.model_validate(
        {
            "tables": [
                {
                    "name": "t",
                    "columns": [{"name": "amount", "type": "number"}],
                    "definitions": [
                        {"name": "big", "expr": "amount > 100"},
                        {"name": "d", "expr": "big and amount < 500"},
                    ],
                }
            ]
        }
    )
    attach_compiled_definitions(dictionary, dialect, set(dictionary.tables))
    records = {r.name: r for r in dictionary.tables["t"].compiled_definitions}
    assert records["d"].sql == expected


def test_a_backquoted_identifier_survives_composition_on_databricks():
    # A doubled backtick is one literal backtick, so the scanner must not read
    # it as the end of the identifier and lose its place.
    dictionary = DataDictionary.model_validate(
        {
            "tables": [
                {
                    "name": "t",
                    "columns": [{"name": "we`ird", "type": "number"}],
                    "definitions": [
                        {"name": "big", "expr": "`we``ird` > 100"},
                        {"name": "d", "expr": "big and `we``ird` < 500"},
                    ],
                }
            ]
        }
    )
    attach_compiled_definitions(dictionary, "databricks", set(dictionary.tables))
    records = {r.name: r for r in dictionary.tables["t"].compiled_definitions}
    assert records["d"].sql == "(`we``ird` > 100) AND `we``ird` < 500"


@pytest.mark.parametrize("dialect", ["duckdb", "snowflake", "databricks"])
def test_no_compiled_definition_keeps_a_reference_marker(dialect: str):
    """The class the Databricks quoting bug belonged to.

    A marker left in the SQL is a column that does not exist, and it only
    shows up when a definition references a sibling. Rather than testing one
    dialect's quoting, this asserts the invariant over the whole corpus for
    every dialect commons lowers to.
    """
    checked = 0
    for filename in ["core.yaml", "functions.yaml", "language.yaml"]:
        for record in compile_corpus(filename, dialect).values():
            assert "__commons_definition_reference_" not in record.sql, record.name
            checked += 1
    assert checked == 42

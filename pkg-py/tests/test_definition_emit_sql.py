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


def compile_corpus(filename: str, dialect: str) -> dict:
    path = SHARED_DIR / "definition-export" / "valid" / filename
    dictionary = DataDictionary.model_validate(
        yaml.safe_load(path.read_text(encoding="utf-8"))
    )
    attach_compiled_definitions(dictionary, dialect)
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
                record = compiled[target][key]
                assert record.target == target, key
                if "code" in expected:
                    assert record.sql == expected["code"], f"{filename} {key} {target}"
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
        attach_compiled_definitions(dictionary, "postgresql")


@pytest.mark.parametrize("dialect", ["snowflake", "databricks"])
def test_every_corpus_definition_lowers_for_both_warehouses(dialect: str):
    total = 0
    for filename in ["core.yaml", "functions.yaml", "language.yaml"]:
        records = compile_corpus(filename, dialect)
        assert records
        total += len(records)
    assert total == 42

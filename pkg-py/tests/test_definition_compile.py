"""Binding export records to a source, and the two attach points.

Phase 1 runs when a dictionary is read and needs no source. Phase 2 runs at
`data_source()`, where a dialect is finally known, and fills the
`compiled_definitions` the registry renders.
"""

import json

import duckdb
import pandas as pd
import pytest
import yaml

from commons import data_source
from commons._data_dictionary import DataDictionary
from commons._definitions import build_registry, expand_tokens
from commons._definitions._compile import attach_compiled_definitions, mixed_grain
from commons._definitions._export import export_spec
from tests._shared import SHARED_DIR, load_shared_fixture


def dictionary_yaml(*definitions: dict, columns: list[dict] | None = None) -> dict:
    return {
        "tables": [
            {
                "name": "orders",
                "columns": columns
                if columns is not None
                else [
                    {"name": "amount", "type": "number(quantity)"},
                    {"name": "region", "type": "string"},
                ],
                "definitions": list(definitions),
            }
        ]
    }


def compiled(*definitions: dict, **kwargs) -> list:
    dictionary = DataDictionary.model_validate(dictionary_yaml(*definitions, **kwargs))
    attach_compiled_definitions(dictionary, "duckdb", {"orders"})
    return dictionary.tables["orders"].compiled_definitions


def by_name(records: list) -> dict:
    return {record.name: record for record in records}


# --- grain -----------------------------------------------------------------


def test_grain_matches_the_shared_contract():
    fixture = load_shared_fixture("definitions")["mixed_grain"]
    paths = sorted((SHARED_DIR / "definition-export" / "valid").glob("*.yaml"))
    assert paths
    checked = 0
    for path in paths:
        exported = export_spec(yaml.safe_load(path.read_text(encoding="utf-8")))
        for key, expected in fixture[path.name].items():
            table, name = key.split("::")
            grain = mixed_grain(exported[table].definitions)
            assert grain[name] is expected, key
            checked += 1
    assert checked == 42


def test_composed_sql_matches_the_shared_contract():
    fixture = load_shared_fixture("definitions")["composed"]
    paths = sorted((SHARED_DIR / "definition-export" / "valid").glob("*.yaml"))
    assert paths
    checked = 0
    for path in paths:
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
        dictionary = DataDictionary.model_validate(raw)
        attach_compiled_definitions(dictionary, "duckdb", set(dictionary.tables))
        for table in dictionary.tables.values():
            for record in table.compiled_definitions:
                expected = fixture[path.name][f"{record.table}::{record.name}"]
                assert record.sql == expected["sql"], record.name
                assert record.notes == expected["notes"], record.name
                checked += 1
    assert checked == 42


def test_a_row_expression_holding_an_aggregate_is_mixed_grain():
    records = by_name(compiled({"name": "d", "expr": "amount > avg(amount)"}))
    assert records["d"].mixed_grain is True


def test_a_plain_row_expression_is_not_mixed_grain():
    assert by_name(compiled({"name": "d", "expr": "amount > 0"}))["d"].mixed_grain is (
        False
    )


def test_an_aggregate_is_not_mixed_grain():
    assert by_name(compiled({"name": "d", "expr": "sum(amount)"}))["d"].mixed_grain is (
        False
    )


def test_mixed_grain_is_inherited_through_a_reference():
    records = by_name(
        compiled(
            {"name": "big", "expr": "amount > avg(amount)"},
            {"name": "d", "expr": "big and region = 'x'"},
        )
    )
    assert records["d"].mixed_grain is True


def test_a_mixed_grain_metric_cannot_be_compiled():
    # A metric whose chain mixes row and aggregate grain needs a subquery
    # rewrite, which one SQL expression cannot express.
    with pytest.raises(ValueError, match="one SQL expression"):
        compiled(
            {"name": "flag", "expr": "amount > avg(amount)"},
            {"name": "d", "expr": "sum(case when flag then 1 else 0 end)"},
        )


# --- composition -----------------------------------------------------------


def test_a_referenced_definition_is_inlined_and_parenthesised():
    records = by_name(
        compiled(
            {"name": "big", "expr": "amount > 100"},
            {"name": "d", "expr": "big and region = 'x'"},
        )
    )
    assert records["d"].sql == '("amount" > 100) AND "region" = \'x\''


def test_composition_follows_a_chain():
    records = by_name(
        compiled(
            {"name": "a", "expr": "amount > 1"},
            {"name": "b", "expr": "a and amount < 10"},
            {"name": "c", "expr": "b or region = 'x'"},
        )
    )
    assert records["c"].sql == (
        '(("amount" > 1) AND "amount" < 10) OR "region" = \'x\''
    )


def test_composition_merges_the_notes_of_what_it_inlined():
    records = by_name(
        compiled(
            {"name": "big", "expr": "amount > 100"},
            {"name": "d", "expr": "big and region = 'x'"},
        )
    )
    # The NaN note belongs to the numeric comparison inside `big`.
    assert any("NaN" in note for note in records["d"].notes)


def test_a_string_that_looks_like_a_definition_name_is_not_substituted():
    records = by_name(
        compiled(
            {"name": "big", "expr": "amount > 100"},
            {"name": "d", "expr": "big and region = 'big'"},
        )
    )
    assert records["d"].sql.endswith("\"region\" = 'big'")


def test_a_string_literal_holding_marker_text_is_not_substituted():
    # `big` is the first definition, so its marker is
    # `__commons_definition_reference_001__`. A string literal holding that
    # exact text must survive: only the quoted identifier is a reference.
    records = by_name(
        compiled(
            {"name": "big", "expr": "amount > 100"},
            {
                "name": "d",
                "expr": "big and region = '__commons_definition_reference_001__'",
            },
        )
    )
    assert records["d"].sql == (
        '("amount" > 100) AND "region" = \'__commons_definition_reference_001__\''
    )


def test_a_column_named_like_a_marker_is_not_confused_with_one():
    # The marker pool skips names the dictionary already uses, so `big`'s
    # marker grows a suffix and the real column is left alone.
    marker_named_column = {
        "name": "__commons_definition_reference_001__",
        "type": "number",
    }
    records = by_name(
        compiled(
            {"name": "big", "expr": "amount > 100"},
            {"name": "d", "expr": "big and __commons_definition_reference_001__ > 0"},
            columns=[
                {"name": "amount", "type": "number"},
                {"name": "region", "type": "string"},
                marker_named_column,
            ],
        )
    )
    assert records["d"].sql == (
        '("amount" > 100) AND "__commons_definition_reference_001__" > 0'
    )


def test_an_unreferenced_definition_keeps_its_own_sql():
    records = by_name(compiled({"name": "d", "expr": "amount > 0"}))
    assert records["d"].sql == '"amount" > 0'


# --- the record ------------------------------------------------------------


def test_the_record_carries_what_the_registry_needs():
    record = by_name(compiled({"name": "d", "expr": "sum(amount)", "label": "Total"}))[
        "d"
    ]
    assert record.name == "d"
    assert record.kind == "metric"
    assert record.type == "number"
    assert record.label == "Total"
    assert record.target == "SQL(duckdb)"
    assert record.expression == "sum(amount)"
    assert record.columns == ["amount"]


# --- the dialect gate ------------------------------------------------------


def test_a_dialect_with_no_emitter_is_refused():
    # Only DuckDB is supported so far. A source commons cannot lower for must
    # fail at construction rather than emit the wrong dialect's SQL.
    with pytest.raises(ValueError, match="postgresql"):
        dictionary = DataDictionary.model_validate(
            dictionary_yaml({"name": "d", "expr": "amount > 0"})
        )
        attach_compiled_definitions(dictionary, "postgresql", {"orders"})


def test_a_dictionary_with_no_definitions_needs_no_emitter():
    dictionary = DataDictionary.model_validate(
        {"tables": [{"name": "orders", "columns": [{"name": "amount"}]}]}
    )
    attach_compiled_definitions(dictionary, "postgresql", {"orders"})
    assert dictionary.tables["orders"].compiled_definitions == []


# --- phase 1: reading a dictionary ----------------------------------------


def test_an_invalid_definition_fails_when_the_dictionary_is_read():
    # Before any source exists, so both packages report it at the same point.
    with pytest.raises(ValueError):
        DataDictionary.model_validate(
            dictionary_yaml({"name": "d", "expr": "nope > 1"})
        )


def test_a_valid_dictionary_reads_and_keeps_its_authored_definitions():
    dictionary = DataDictionary.model_validate(
        dictionary_yaml({"name": "d", "expr": "amount > 0"})
    )
    assert dictionary.tables["orders"].definitions["d"].expr == "amount > 0"
    # Nothing is compiled yet: that needs a source.
    assert dictionary.tables["orders"].compiled_definitions == []


# --- phase 2: end to end through a real source ----------------------------


@pytest.fixture
def source(tmp_path):
    path = tmp_path / "data-dict.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "tables": [
                    {
                        "name": "orders",
                        "columns": [
                            {"name": "amount", "type": "number"},
                            {"name": "region", "type": "string"},
                        ],
                        "definitions": [
                            {"name": "big", "expr": "amount > 100"},
                            {
                                "name": "big emea",
                                "expr": "big and region = 'EMEA'",
                            },
                            {"name": "total", "expr": "sum(amount)"},
                        ],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    frame = pd.DataFrame({"amount": [50, 150, 250], "region": ["EMEA", "EMEA", "AMER"]})
    return data_source(orders=frame, dictionary=path)


def test_a_source_compiles_the_dictionary_it_was_given(source):
    records = by_name(source.dictionary.tables["orders"].compiled_definitions)
    assert sorted(records) == ["big", "big emea", "total"]
    assert records["total"].sql == 'sum("amount")'


def test_a_compiled_definition_reaches_the_registry(source):
    registry = build_registry({"orders_db": source})
    records = registry.for_source("orders_db")
    assert sorted(record.name for record in records) == [
        "big",
        "big emea",
        "total",
    ]
    assert all(record.table == "orders" for record in records)


def test_an_expanded_token_runs_against_the_real_source(source):
    registry = build_registry({"orders_db": source})
    query, used = expand_tokens(
        "SELECT count(*) FROM orders WHERE {{big emea}}", registry.for_source()
    )
    assert [record.name for record in used] == ["big emea"]
    result = source.backend.connection.execute(query).fetchone()
    # One row is over 100 and in EMEA.
    assert result[0] == 1


def test_an_expanded_metric_runs_against_the_real_source(source):
    registry = build_registry({"orders_db": source})
    query, _ = expand_tokens("SELECT {{total}} FROM orders", registry.for_source())
    assert source.backend.connection.execute(query).fetchone()[0] == 450


def test_every_corpus_definition_compiles_to_sql_duckdb_accepts():
    """The emitter's output is parsed by DuckDB, not just compared to a string.

    A fixture can only say the text matches what data-dict produced. This says
    DuckDB can parse it. Binding it would need a real table per corpus
    dictionary with matching column types, which is more fixture than the
    question deserves, so this checks syntax only.
    """
    connection = duckdb.connect()
    checked = 0
    for path in sorted((SHARED_DIR / "definition-export" / "valid").glob("*.yaml")):
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
        dictionary = DataDictionary.model_validate(raw)
        attach_compiled_definitions(dictionary, "duckdb", set(dictionary.tables))
        for table in dictionary.tables.values():
            for record in table.compiled_definitions:
                # `json_serialize_sql` reports a parse failure in its result
                # rather than raising, so the result is what gets asserted.
                row = connection.execute(
                    "SELECT json_serialize_sql(?)", [f"SELECT {record.sql}"]
                ).fetchone()
                assert row is not None
                assert json.loads(row[0])["error"] is False, record.sql
                checked += 1
    assert checked == 42


def test_definitions_on_a_table_the_source_does_not_expose_fail_construction(
    tmp_path,
):
    """Caught at `data_source()`, not deferred to the registry.

    Waiting for `build_registry()` would let the compiled records reach the
    dictionary's retrieval chunks first, describing a table the agent cannot
    query.
    """
    path = tmp_path / "data-dict.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "tables": [
                    {
                        "name": "elsewhere",
                        "columns": [{"name": "amount", "type": "number"}],
                        "definitions": [{"name": "big", "expr": "amount > 100"}],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="does not expose"):
        data_source(orders=pd.DataFrame({"amount": [1]}), dictionary=path)


def test_a_refused_compile_leaves_the_dictionary_untouched():
    # `orders` compiles before `elsewhere` is refused, so this only passes
    # if nothing is assigned until every table succeeds — leaving the
    # dictionary reusable for another source.
    dictionary = DataDictionary.model_validate(
        {
            "tables": [
                {
                    "name": "orders",
                    "columns": [{"name": "amount", "type": "number"}],
                    "definitions": [{"name": "big", "expr": "amount > 100"}],
                },
                {
                    "name": "elsewhere",
                    "columns": [{"name": "amount", "type": "number"}],
                    "definitions": [{"name": "big", "expr": "amount > 100"}],
                },
            ]
        }
    )
    with pytest.raises(ValueError, match="does not expose"):
        attach_compiled_definitions(dictionary, "duckdb", {"orders"})
    assert dictionary.tables["orders"].compiled_definitions == []


def test_a_table_without_definitions_need_not_be_exposed(tmp_path):
    # Prose about a table the source does not expose is the author's business;
    # only a definition would produce SQL against something that is not there.
    path = tmp_path / "data-dict.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "tables": [
                    {"name": "elsewhere", "description": "Documented elsewhere."},
                    {
                        "name": "orders",
                        "columns": [{"name": "amount", "type": "number"}],
                        "definitions": [{"name": "big", "expr": "amount > 100"}],
                    },
                ]
            }
        ),
        encoding="utf-8",
    )
    source = data_source(orders=pd.DataFrame({"amount": [1]}), dictionary=path)
    assert source.dictionary is not None

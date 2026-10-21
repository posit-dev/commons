"""Binding a definition to the names a warehouse actually uses.

A definition's expression names the columns the author wrote. A catalog
import re-keys the dictionary to what the warehouse reported, which on
Snowflake means upper case, so the expression has to be rewritten before it
is lowered or the SQL would name columns the warehouse does not have.
"""

import pytest

from commons._data_dictionary import DataDictionary
from commons._definitions._compile import (
    DefinitionAbsentColumnError,
    DefinitionUnmatchedTableError,
    _bind_ir,
    attach_compiled_definitions,
)
from commons._definitions._export import Ir
from tests._shared import load_shared_fixture
from tests._warehouse import merge_shared_case

_BINDING_ERRORS = {
    "absent_column": DefinitionAbsentColumnError,
    "unmatched_table": DefinitionUnmatchedTableError,
}


def compile_shared_case(case: dict) -> dict[str, dict[str, str]]:
    merged = merge_shared_case(case)
    attach_compiled_definitions(
        merged.dictionary,
        case["backend"],
        set(merged.dictionary.tables),
        merged.definition_bindings,
    )
    return {
        label: {record.name: record.sql for record in table.compiled_definitions}
        for label, table in merged.dictionary.tables.items()
        if table.compiled_definitions
    }


def test_definition_binding_matches_the_shared_contract():
    cases = load_shared_fixture("definition-binding")["cases"]
    assert cases
    for case in cases:
        expect = case["expect"]
        if "error" in expect:
            with pytest.raises(_BINDING_ERRORS[expect["error"]]):
                compile_shared_case(case)
            continue
        assert compile_shared_case(case) == expect["tables"], case["name"]


def test_a_selection_is_bound_on_the_node_that_carries_it_too():
    # A COLUMNS(...) node keeps its own copy of the resolved selection. The
    # emitters read the export record's copy, but two copies that disagree
    # are a trap for whoever reads the tree next.
    node = Ir(
        kind="selected",
        type="any",
        shape="row",
        attrs={
            "selection": {
                "form": "regex",
                "pattern": "^i",
                "columns": [{"name": "id", "path": "id", "type": "number"}],
            }
        },
    )

    bound = _bind_ir(node, {"id": "ID"}, "any_set", "sales")

    assert [column["path"] for column in bound.attrs["selection"]["columns"]] == ["ID"]


def test_without_bindings_a_definition_keeps_the_authored_spelling():
    authored = DataDictionary.model_validate(
        {
            "tables": [
                {
                    "name": "sales",
                    "columns": [{"name": "id", "type": "number(quantity)"}],
                    "definitions": [{"name": "total", "expr": "sum(id)"}],
                }
            ]
        }
    )

    attach_compiled_definitions(authored, "snowflake", {"sales"})

    records = authored.tables["sales"].compiled_definitions
    assert records[0].sql == 'sum("id")'

"""Binding a definition to the names a warehouse actually uses.

A definition's expression names the columns the author wrote. A catalog
import re-keys the dictionary to what the warehouse reported, which on
Snowflake means upper case, so the expression has to be rewritten before it
is lowered or the SQL would name columns the warehouse does not have.
"""

import pytest

from commons._catalog._import import import_catalog
from commons._data_dictionary import DataDictionary
from commons._definitions._compile import (
    _bind_ir,
    _reference_markers,
    attach_compiled_definitions,
)
from commons._definitions._export import DefinitionExport, Ir
from tests._warehouse import FakeWarehouse


def dictionary(*definitions: dict, columns: list[dict] | None = None):
    return DataDictionary.model_validate(
        {
            "tables": [
                {
                    "name": "sales",
                    "columns": columns
                    if columns is not None
                    else [{"name": "id", "type": "number(quantity)"}],
                    "definitions": list(definitions),
                }
            ]
        }
    )


def imported_sql(*definitions: dict, columns: list[dict] | None = None):
    """Every definition's SQL, as a warehouse source would compile it."""
    imported = import_catalog(
        FakeWarehouse(), dictionary=dictionary(*definitions, columns=columns)
    )
    attach_compiled_definitions(
        imported.dictionary,
        "snowflake",
        set(imported.tables),
        imported.definition_bindings,
    )
    assert imported.dictionary is not None
    entry = imported.dictionary.tables["ANALYTICS.PUBLIC.SALES"]
    return {record.name: record.sql for record in entry.compiled_definitions}


def test_a_column_is_lowered_with_the_spelling_the_warehouse_reported():
    compiled = imported_sql({"name": "total", "expr": "sum(id)"})

    assert compiled["total"] == 'sum("ID")'


def test_a_sibling_reference_is_bound_through_its_own_expression():
    compiled = imported_sql(
        {"name": "total", "expr": "sum(id)"},
        {"name": "doubled", "expr": "total * 2"},
    )

    assert compiled["doubled"] == '(sum("ID")) * 2'


def test_a_selection_is_bound_column_by_column():
    compiled = imported_sql({"name": "any_set", "expr": "COLUMNS('^i') IS NOT NULL"})

    assert '"ID"' in compiled["any_set"]
    assert '"id"' not in compiled["any_set"]


def test_a_column_inside_a_case_branch_is_bound_too():
    # CASE keeps its branches as a list of condition-and-result pairs, so a
    # walk that only descends into nodes it finds directly under a key walks
    # past every column reference in them.
    compiled = imported_sql(
        {"name": "flagged", "expr": "CASE WHEN id > 0 THEN 1 ELSE 0 END"}
    )

    assert '"ID"' in compiled["flagged"]
    assert '"id"' not in compiled["flagged"]


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


def test_a_definition_over_a_column_the_relation_lacks_is_refused():
    # An authored column the warehouse never reported survives the merge, so
    # the definition type-checks against the dictionary and only binding can
    # catch that there is no such column to read.
    with pytest.raises(ValueError, match="absent from the selected relation"):
        imported_sql(
            {"name": "total", "expr": "sum(absent)"},
            columns=[
                {"name": "id", "type": "number(quantity)"},
                {"name": "absent", "type": "number(quantity)"},
            ],
        )


def test_an_authored_table_that_matched_nothing_takes_its_definitions_with_it():
    imported = import_catalog(
        FakeWarehouse(),
        dictionary=DataDictionary.model_validate(
            {
                "tables": [
                    {
                        "name": "unmatched",
                        "columns": [{"name": "id", "type": "number(quantity)"}],
                        "definitions": [{"name": "total", "expr": "sum(id)"}],
                    }
                ]
            }
        ),
    )

    with pytest.raises(ValueError, match="does not match an exposed relation"):
        attach_compiled_definitions(
            imported.dictionary,
            "snowflake",
            set(imported.tables),
            imported.definition_bindings,
        )


def test_without_bindings_a_definition_keeps_the_authored_spelling():
    authored = dictionary({"name": "total", "expr": "sum(id)"})

    attach_compiled_definitions(authored, "snowflake", {"sales"})

    records = authored.tables["sales"].compiled_definitions
    assert records[0].sql == 'sum("id")'


def test_a_bound_selection_cannot_be_mistaken_for_a_reference_marker():
    """A physical column named like a marker must not shadow a reference.

    Binding chooses the physical spelling, so nothing stops a warehouse
    column from being named exactly like the marker a sibling reference is
    substituted through. The selection carries that name outside the tree's
    column nodes, which is the path the collision set used to miss.
    """
    marker = "__commons_definition_reference_001__"
    markers = _reference_markers(
        {
            "base": DefinitionExport(
                name="base",
                label=None,
                description=None,
                details=None,
                todo=None,
                expression="sum(id)",
                kind="metric",
                type="number",
                columns=["id"],
                definitions=[],
                selection={"columns": [{"path": [marker]}]},
            )
        }
    )

    assert markers["base"] != marker

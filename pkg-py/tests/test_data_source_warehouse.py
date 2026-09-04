"""A data source over a warehouse connection.

What the catalog import produces is covered against the import itself; this
is about the source it becomes: which tables it exposes, what it remembers
about access, and what it refuses once the connection is no longer the one
the catalog was read for.
"""

import pytest
import sqlalchemy

from commons import data_source
from commons._catalog import CatalogSessionChangedError
from commons._data_dictionary import DataDictionary
from commons._data_source import DataSource
from tests._warehouse import FakeWarehouse


def warehouse_source(backend=None, **kwargs) -> DataSource:
    return DataSource._from_warehouse(
        backend or FakeWarehouse(),
        kwargs.pop("tables", None),
        kwargs.pop("exclude", None),
        kwargs.pop("dictionary", None),
    )


def test_a_warehouse_source_exposes_its_catalog_labels():
    source = warehouse_source()

    assert source.tables == ["ANALYTICS.PUBLIC.SALES", "ANALYTICS.PUBLIC.ORDERS"]
    assert source.table_ids["ANALYTICS.PUBLIC.SALES"].catalog == "ANALYTICS"
    assert source.manifest is not None
    assert source.relations is not None


def test_a_warehouse_source_carries_the_session_it_was_built_for():
    backend = FakeWarehouse()
    source = warehouse_source(backend)

    assert source.session is not None

    backend.role = "ADMIN"
    with pytest.raises(CatalogSessionChangedError):
        source.query("SELECT * FROM sales")


def test_a_warehouse_engine_reaches_the_catalog_import(monkeypatch):
    # The backend is the seam: everything above it is the real dispatch, from
    # data_source() through from_engine()'s warehouse branch.
    backend = FakeWarehouse()
    monkeypatch.setattr("commons._data_source.EngineBackend", lambda engine: backend)

    source = data_source(sqlalchemy.create_engine("sqlite://"), exclude=["ORD*"])

    assert source.tables == ["ANALYTICS.PUBLIC.SALES"]
    assert source.session is not None
    assert source.manifest is not None


def test_a_source_over_anything_else_has_no_session_to_check(tmp_path):
    engine = sqlalchemy.create_engine(f"sqlite:///{tmp_path / 'db.sqlite'}")
    with engine.begin() as connection:
        connection.execute(sqlalchemy.text("CREATE TABLE sales (id INTEGER)"))
    source = DataSource.from_engine(engine)

    assert source.session is None
    assert source.query("SELECT * FROM sales") == []


def test_exclude_is_refused_by_a_backend_with_no_catalog_listing(tmp_path):
    engine = sqlalchemy.create_engine(f"sqlite:///{tmp_path / 'db.sqlite'}")

    with pytest.raises(ValueError, match="Snowflake and Databricks"):
        DataSource.from_engine(engine, exclude=["staging_*"])


def test_definitions_the_warehouse_spells_differently_are_refused():
    # Until the compiler can bind an authored name to the discovered one, a
    # definition over a renamed column would lower to SQL naming a column
    # that is not there, so construction fails instead.
    dictionary = DataDictionary.model_validate(
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

    with pytest.raises(NotImplementedError, match="does not have column"):
        warehouse_source(dictionary=dictionary)


def sales_dictionary(**table):
    return DataDictionary.model_validate(
        {
            "tables": [
                {
                    "name": "sales",
                    "columns": [{"name": "id", "type": "number(quantity)"}],
                    **table,
                }
            ]
        }
    )


def test_a_definition_survives_the_rekeying_a_merge_does(monkeypatch):
    # The merge re-keys the dictionary to the warehouse's label, and the
    # definition's export records are still keyed by the authored name.
    backend = FakeWarehouse(columns=["id"])
    monkeypatch.setattr("commons._data_source.EngineBackend", lambda engine: backend)
    dictionary = sales_dictionary(definitions=[{"name": "total", "expr": "sum(id)"}])

    source = data_source(sqlalchemy.create_engine("sqlite://"), dictionary=dictionary)

    assert source.dictionary is not None
    entry = source.dictionary.tables["ANALYTICS.PUBLIC.SALES"]
    assert [record.name for record in entry.compiled_definitions] == ["total"]


def test_a_definition_on_a_table_that_matched_nothing_is_refused(monkeypatch):
    backend = FakeWarehouse(columns=["id"])
    monkeypatch.setattr("commons._data_source.EngineBackend", lambda engine: backend)
    dictionary = DataDictionary.model_validate(
        {
            "tables": [
                {
                    "name": "unmatched",
                    "columns": [{"name": "id", "type": "number(quantity)"}],
                    "definitions": [{"name": "total", "expr": "sum(id)"}],
                }
            ]
        }
    )

    with pytest.raises(ValueError, match="does not match an exposed relation"):
        data_source(sqlalchemy.create_engine("sqlite://"), dictionary=dictionary)

"""Importing a warehouse catalog for a data source.

The reader queries are already covered per backend; what is checked here is
the order the import puts them in, since that order is what makes the source
safe: nothing is described before its access is verified, and the session is
the same one at the end as at the start.
"""

import pytest

from commons._catalog import CatalogSessionChangedError, Selector
from commons._catalog._import import import_catalog, is_warehouse
from commons._data_dictionary import DataDictionary
from tests._warehouse import FakeWarehouse


def test_only_warehouse_backends_import_a_catalog():
    assert is_warehouse(FakeWarehouse())
    assert is_warehouse(FakeWarehouse(dialect="databricks"))
    assert not is_warehouse(FakeWarehouse(dialect="duckdb"))


def test_an_unset_selection_takes_the_current_namespace():
    backend = FakeWarehouse()

    imported = import_catalog(backend)

    assert imported.tables == ["ANALYTICS.PUBLIC.SALES", "ANALYTICS.PUBLIC.ORDERS"]
    assert imported.session is not None
    assert imported.session.principal == "ANALYST"


def test_a_namespace_is_named_with_a_selector():
    backend = FakeWarehouse()

    imported = import_catalog(backend, Selector(catalog="ANALYTICS", schema="PUBLIC"))

    assert list(imported.relations) == [
        "ANALYTICS.PUBLIC.SALES",
        "ANALYTICS.PUBLIC.ORDERS",
    ]
    assert imported.manifest.access == dict.fromkeys(imported.tables, "unknown")


def test_a_dotted_string_names_one_relation():
    backend = FakeWarehouse()

    imported = import_catalog(backend, "ANALYTICS.PUBLIC.SALES")

    assert imported.tables == ["ANALYTICS.PUBLIC.SALES"]


def test_a_named_relation_is_access_checked_before_the_source_exists():
    backend = FakeWarehouse()
    backend.refuse = {"SALES"}

    with pytest.raises(Exception, match="not authorized"):
        import_catalog(backend, "ANALYTICS.PUBLIC.SALES")


def test_what_the_import_probed_is_remembered_as_readable():
    # A relation checked on the way in should not be probed again the first
    # time an agent touches it.
    imported = import_catalog(FakeWarehouse(), "ANALYTICS.PUBLIC.SALES")

    assert imported.manifest.access == {"ANALYTICS.PUBLIC.SALES": "queryable"}


def test_a_selection_resolving_to_nothing_is_an_error():
    backend = FakeWarehouse(relations=[])

    with pytest.raises(ValueError, match="no objects"):
        import_catalog(backend)


def test_an_excluded_relation_is_left_out():
    backend = FakeWarehouse()

    imported = import_catalog(backend, exclude=["ORD*"])

    assert imported.tables == ["ANALYTICS.PUBLIC.SALES"]


def test_a_session_that_moves_during_discovery_is_refused():
    class Moving(FakeWarehouse):
        def query(self, sql):
            rows = super().query(sql)
            if sql.startswith("SELECT CURRENT_USER()"):
                self.role = "ADMIN"
            return rows

    with pytest.raises(CatalogSessionChangedError):
        import_catalog(Moving())


def test_an_authored_dictionary_is_rekeyed_to_the_warehouse_labels():
    backend = FakeWarehouse()
    dictionary = DataDictionary.model_validate(
        {"tables": [{"name": "sales", "description": "Authored prose"}]}
    )

    imported = import_catalog(backend, dictionary=dictionary)

    assert imported.dictionary is not None
    assert list(imported.dictionary.tables) == ["ANALYTICS.PUBLIC.SALES"]
    table = imported.dictionary.tables["ANALYTICS.PUBLIC.SALES"]
    assert table.description == "Authored prose"
    assert list(table.columns) == ["ID"]


def test_an_unauthorized_table_stops_the_dictionary_merge():
    backend = FakeWarehouse()
    backend.refuse = {"SALES"}
    dictionary = DataDictionary.model_validate(
        {"tables": [{"name": "sales", "description": "Prose"}]}
    )

    with pytest.raises(Exception, match="not authorized"):
        import_catalog(backend, dictionary=dictionary)

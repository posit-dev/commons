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
from commons._data_source import TableId
from tests._warehouse import FakeDatabricks, FakeWarehouse


def test_only_warehouse_backends_import_a_catalog():
    assert is_warehouse(FakeWarehouse())
    assert is_warehouse(FakeDatabricks())
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


def test_construction_probes_are_not_carried_into_the_manifest():
    # Every relation starts unknown, including the ones construction just
    # probed. Carrying that answer forward would serve a grant revoked
    # between construction and first touch, so first touch re-probes.
    imported = import_catalog(FakeWarehouse(), "ANALYTICS.PUBLIC.SALES")

    assert imported.manifest.access == {"ANALYTICS.PUBLIC.SALES": "unknown"}


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


def _prose() -> DataDictionary:
    """A dictionary that matches SALES, so the merge describes it."""
    return DataDictionary.model_validate(
        {"tables": [{"name": "sales", "description": "Authored prose"}]}
    )


def _kinds(queries: list[str]) -> list[str]:
    """Each query as the step it belongs to, so order can be asserted."""
    steps = []
    for sql in queries:
        if sql.startswith(("SELECT CURRENT_USER()",)):
            steps.append("session")
        elif sql.startswith(("SELECT CURRENT_DATABASE()", "SELECT CURRENT_CATALOG()")):
            steps.append("namespace")
        elif sql.startswith("SHOW OBJECTS") or "information_schema.tables" in sql:
            steps.append("list")
        elif (
            sql.startswith(("DESC TABLE", "DESCRIBE TABLE"))
            or "information_schema.columns" in sql
        ):
            steps.append("describe")
        elif sql.startswith("SELECT * FROM"):
            steps.append("probe")
        else:
            raise AssertionError(f"unclassified query: {sql}")
    return steps


def test_the_session_is_read_before_anything_it_decides():
    backend = FakeWarehouse()

    import_catalog(backend, "ANALYTICS.PUBLIC.SALES")

    # Every access answer that follows was decided for this identity, so
    # reading it second would be reading it about a different connection.
    assert _kinds(backend.queries)[0] == "session"


def test_a_named_relation_is_probed_before_it_is_described():
    backend = FakeWarehouse()

    import_catalog(backend, "ANALYTICS.PUBLIC.SALES", dictionary=_prose())

    steps = _kinds(backend.queries)
    # A name the caller got wrong should fail at construction, which only
    # holds if the probe precedes the describe that would otherwise reveal it.
    assert steps.index("probe") < steps.index("describe")


def test_the_session_is_read_again_after_discovery():
    backend = FakeWarehouse()

    import_catalog(backend, "ANALYTICS.PUBLIC.SALES", dictionary=_prose())

    steps = _kinds(backend.queries)
    # A role that moved during discovery invalidates what was just learned,
    # so the second read has to come after the last thing it invalidates.
    assert steps[-1] == "session"
    assert steps.count("session") == 2
    assert steps.index("describe") < len(steps) - 1


def test_a_databricks_selection_is_imported_the_same_way():
    backend = FakeDatabricks()

    imported = import_catalog(backend, dictionary=_databricks_prose())

    assert imported.tables == ["main.sales.sales", "main.sales.orders"]
    assert imported.session is not None
    assert imported.session.principal == "analyst@example.com"
    # Databricks reports no role, so there is none to snapshot.
    assert imported.session.role is None
    assert _kinds(backend.queries)[0] == "session"
    assert _kinds(backend.queries)[-1] == "session"


def test_a_databricks_authored_name_matches_whatever_its_case():
    # Databricks reports lower-cased identifiers, so an authored name in any
    # other case still has to find the relation it describes.
    backend = FakeDatabricks()

    imported = import_catalog(backend, dictionary=_databricks_prose("SALES"))

    assert imported.dictionary is not None
    table = imported.dictionary.tables["main.sales.sales"]
    assert table.description == "Authored prose"


def test_a_databricks_relation_is_probed_before_it_is_described():
    backend = FakeDatabricks()

    import_catalog(backend, "main.sales.orders", dictionary=_databricks_prose("orders"))

    steps = _kinds(backend.queries)
    assert steps.index("probe") < steps.index("describe")


def _databricks_prose(name: str = "sales") -> DataDictionary:
    return DataDictionary.model_validate(
        {"tables": [{"name": name, "description": "Authored prose"}]}
    )


def test_an_empty_selection_is_refused():
    with pytest.raises(ValueError, match="at least one relation or namespace"):
        import_catalog(FakeWarehouse(), [])


def test_a_selection_entry_with_an_empty_component_is_refused():
    with pytest.raises(ValueError, match="empty name components"):
        import_catalog(FakeWarehouse(), "ANALYTICS..SALES")


def test_a_selection_entry_of_the_wrong_type_is_refused():
    with pytest.raises(TypeError, match="table name or a TableId"):
        import_catalog(FakeWarehouse(), 5)


def test_a_table_id_names_one_relation():
    imported = import_catalog(
        FakeWarehouse(), TableId(catalog="ANALYTICS", schema="PUBLIC", table="SALES")
    )

    assert imported.tables == ["ANALYTICS.PUBLIC.SALES"]


def test_a_named_relation_the_warehouse_lacks_fails_construction():
    with pytest.raises(ValueError, match="does not have"):
        import_catalog(FakeWarehouse(), "ANALYTICS.PUBLIC.MISSING")


def test_exclude_that_empties_the_selection_says_so():
    with pytest.raises(ValueError, match="dropped every relation"):
        import_catalog(FakeWarehouse(), exclude=["*"])


def test_an_exclude_that_matched_nothing_does_not_blame_exclude():
    # The namespace was already empty, so exclude is not what emptied it.
    backend = FakeWarehouse(relations=[])

    with pytest.raises(ValueError, match="contains no objects") as refusal:
        import_catalog(backend, exclude=["NOTHING_*"])

    assert "dropped every relation" not in str(refusal.value)


def test_excluding_a_name_the_warehouse_never_had_does_not_blame_exclude():
    # The relation was absent, not dropped, so exclude is not the reason
    # there is nothing left to expose.
    with pytest.raises(ValueError, match="contains no objects") as refusal:
        import_catalog(
            FakeWarehouse(), "ANALYTICS.PUBLIC.MISSING", exclude=["MISSING"]
        )

    assert "dropped every relation" not in str(refusal.value)

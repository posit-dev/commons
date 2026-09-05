"""Merging a warehouse catalog into an authored dictionary.

The rules the R side settled and this must keep: authored prose wins,
warehouse types are authoritative, identifier case normalizes per backend,
and an ambiguous relative name is an error rather than a guess.

Everything here is a pure function over the rows a warehouse listing returns,
so it needs no warehouse. The queries that produce those rows are the
per-backend readers.
"""

import pytest

from commons._catalog import (
    Manifest,
    Relation,
    Selector,
    check_exclude,
    excluded,
    id_type,
    merge_dictionary,
    normalize_identifier,
    search,
    table_registry,
)
from commons._data_dictionary import DataDictionary
from commons._data_source import TableId


def relation(label: str, **kwargs) -> Relation:
    parts = label.split(".")
    if len(parts) == 3:
        table_id = TableId(catalog=parts[0], schema=parts[1], table=parts[2])
    elif len(parts) == 2:
        table_id = TableId(schema=parts[0], table=parts[1])
    else:
        table_id = TableId(table=label)
    return Relation(id=table_id, **kwargs)


def warehouse_columns() -> list[dict]:
    return [
        {
            "column": "AMOUNT",
            "type": "NUMBER(38,2)",
            "nullable": True,
            "description": "Warehouse amount description.",
        },
        {
            "column": "ORDER_ID",
            "type": "NUMBER(38,0)",
            "nullable": False,
            "description": "Warehouse key.",
        },
    ]


# --- identifier case -------------------------------------------------------


@pytest.mark.parametrize(
    ("case", "expected"),
    [("upper", "ORDERS"), ("lower", "orders"), (None, "Orders")],
)
def test_identifiers_normalize_per_backend(case, expected):
    assert normalize_identifier("Orders", case) == expected


# --- exclusion globs -------------------------------------------------------


@pytest.mark.parametrize(
    ("pattern", "name", "hidden"),
    [
        ("TMP_*", "TMP_LOAD", True),
        ("TMP_*", "ORDERS", False),
        ("?RDERS", "ORDERS", True),
        ("a.b", "a.b", True),
        ("a.b", "axb", False),
    ],
)
def test_exclusion_globs_match_whole_names(pattern, name, hidden):
    # A glob is anchored, and its dots are literal rather than any character.
    assert excluded([name], [pattern]) == [hidden]


def test_no_patterns_excludes_nothing():
    assert excluded(["a", "b"], []) == [False, False]


@pytest.mark.parametrize("bad", [["", "ok"], "notalist", [None]])
def test_an_invalid_exclude_is_refused(bad):
    with pytest.raises((ValueError, TypeError)):
        check_exclude(bad)


# --- selection -------------------------------------------------------------


def test_a_namespace_selection_lists_and_excludes():
    registry = table_registry(
        selectors=[Selector(catalog="main", schema="sales")],
        exact_relation=lambda table_id: None,
        list_relations=lambda table_id: [
            relation("main.sales.orders", kind="table"),
            relation("main.sales.TMP_LOAD", kind="table"),
        ],
        exclude=["TMP_*"],
    )
    assert list(registry.relations) == ["main.sales.orders"]
    assert registry.namespace_selected is True


def test_a_bare_relation_is_validated_under_the_label_it_came_back_with():
    # A selection entry naming a bare table is qualified by the warehouse
    # from the connection's namespace. The access check pairs the two lists
    # by label, so validate has to carry the qualified one.
    registry = table_registry(
        selectors=[Selector(table="orders")],
        exact_relation=lambda selector: relation("main.sales.orders", kind="table"),
        list_relations=lambda selector: [],
    )

    assert list(registry.relations) == ["main.sales.orders"]
    assert list(registry.validate) == ["main.sales.orders"]


def test_a_bare_relation_the_warehouse_lacks_keeps_the_name_that_was_asked_for():
    registry = table_registry(
        selectors=[Selector(table="orders")],
        exact_relation=lambda selector: None,
        list_relations=lambda selector: [],
    )

    assert list(registry.validate) == ["orders"]
    assert registry.relations["orders"].discovered is False


def test_a_selection_above_the_object_limit_is_refused():
    with pytest.raises(ValueError, match="above the supported limit"):
        table_registry(
            selectors=[Selector(catalog="main", schema="sales")],
            exact_relation=lambda table_id: None,
            list_relations=lambda table_id: [
                relation("main.sales.orders", kind="table"),
                relation("main.sales.TMP_LOAD", kind="table"),
            ],
            object_limit=1,
        )


def test_duplicate_labels_are_refused():
    with pytest.raises(ValueError, match="duplicate labels"):
        table_registry(
            selectors=[Selector(catalog="main", schema="sales")],
            exact_relation=lambda table_id: None,
            list_relations=lambda table_id: [
                relation("main.sales.orders", kind="table"),
                relation("main.sales.orders", kind="view"),
            ],
        )


# --- id shapes -------------------------------------------------------------


def test_a_selector_naming_a_table_is_a_relation():
    assert id_type(Selector(catalog="c", schema="s", table="t")) == "relation"


def test_a_selector_naming_only_a_namespace_is_a_namespace():
    assert id_type(Selector(catalog="c", schema="s")) == "namespace"


@pytest.mark.parametrize(
    "selector",
    [
        Selector(catalog="c", table="t"),
        Selector(catalog="c", schema="", table="t"),
        Selector(),
    ],
)
def test_a_selector_that_skips_a_level_is_refused(selector):
    # Skipping a level makes the remaining components ambiguous, so it is an
    # error rather than a guess about which level was meant.
    with pytest.raises(ValueError):
        id_type(selector)


# --- search ----------------------------------------------------------------


def manifest_for_search() -> Manifest:
    return Manifest.build(
        {
            "main.finance.orders": relation(
                "main.finance.orders",
                kind="table",
                description="Booked commercial activity.",
            ),
            "refunds": relation(
                "refunds", kind="view", description="Returned purchases."
            ),
        },
        namespace_selected=True,
    )


@pytest.mark.parametrize(
    ("query", "expected"),
    [
        ("commercial bookings", ["main.finance.orders"]),
        ("finance", ["main.finance.orders"]),
        ("refund", ["refunds"]),
    ],
)
def test_search_finds_names_and_descriptions(query, expected):
    assert list(search(manifest_for_search(), query)) == expected


def test_search_can_be_restricted_to_a_kind():
    assert search(manifest_for_search(), "refund", kinds=["table"]) == {}


def test_an_empty_query_matches_nothing():
    assert search(manifest_for_search(), "") == {}


def test_search_honours_its_limit():
    assert len(search(manifest_for_search(), "orders refunds", limit=1)) == 1


def test_a_manifest_is_searchable_only_when_the_listing_is_large():
    small = Manifest.build(
        {"a": relation("a")}, namespace_selected=True, prompt_limit=3000
    )
    assert small.searchable is False
    large = Manifest.build(
        {"a": relation("a")}, namespace_selected=True, prompt_limit=0
    )
    assert large.searchable is True


def test_an_explicit_table_list_is_never_searchable():
    # Naming the tables is already the narrowing that search would provide.
    manifest = Manifest.build(
        {"a": relation("a")}, namespace_selected=False, prompt_limit=0
    )
    assert manifest.searchable is False


# --- merging into a dictionary ---------------------------------------------


def merged_fixture():
    dictionary = DataDictionary.model_validate(
        {
            "tables": [
                {
                    "name": "orders",
                    "description": "Authored table description.",
                    "columns": [
                        {
                            "name": "amount",
                            "type": "number(quantity)",
                            "units": "USD",
                            "description": "Authored column description.",
                        },
                        {"name": "missing", "description": "Not in the warehouse."},
                    ],
                },
                {"name": "unselected", "description": "Not selected."},
            ],
            "relationships": [
                {"join": "orders.order_id = unselected.order_id"},
                {"join": "orders.order_id = external.order_id"},
            ],
        }
    )
    relations = {
        "ANALYTICS.PUBLIC.ORDERS": relation(
            "ANALYTICS.PUBLIC.ORDERS",
            kind="table",
            description="Warehouse table description.",
        )
    }
    return merge_dictionary(
        dictionary,
        relations,
        describe_relation=lambda table_id: warehouse_columns(),
        identifier_case="upper",
    )


def test_the_dictionary_is_rekeyed_to_the_selected_relation():
    merged = merged_fixture()
    assert list(merged.dictionary.tables) == ["ANALYTICS.PUBLIC.ORDERS"]


def test_authored_prose_wins_over_the_warehouse():
    table = merged_fixture().dictionary.tables["ANALYTICS.PUBLIC.ORDERS"]
    assert table.description == "Authored table description."


def test_warehouse_prose_fills_a_gap_the_author_left():
    columns = merged_fixture().dictionary.tables["ANALYTICS.PUBLIC.ORDERS"].columns
    assert columns["ORDER_ID"].description == "Warehouse key."


def test_the_warehouse_type_is_authoritative():
    columns = merged_fixture().dictionary.tables["ANALYTICS.PUBLIC.ORDERS"].columns
    assert columns["AMOUNT"].type == "NUMBER(38,2)"
    assert columns["AMOUNT"].nullable is True


def test_authored_detail_the_warehouse_does_not_carry_survives():
    columns = merged_fixture().dictionary.tables["ANALYTICS.PUBLIC.ORDERS"].columns
    assert columns["AMOUNT"].units == "USD"
    assert columns["AMOUNT"].description == "Authored column description."


def test_discovered_columns_come_first_and_authored_only_ones_follow():
    columns = merged_fixture().dictionary.tables["ANALYTICS.PUBLIC.ORDERS"].columns
    assert list(columns) == ["AMOUNT", "ORDER_ID", "missing"]


def test_the_bindings_record_what_each_authored_name_matched():
    merged = merged_fixture()
    assert merged.definition_bindings is not None
    assert merged.definition_bindings["tables"] == {
        "orders": "ANALYTICS.PUBLIC.ORDERS",
        "unselected": None,
    }
    assert merged.definition_bindings["columns"]["orders"] == {
        "amount": "AMOUNT",
        "missing": None,
    }


def test_a_relationship_mentioning_a_dropped_table_is_dropped():
    merged = merged_fixture()
    joins = [item.join for item in merged.dictionary.relationships]
    assert joins == ["orders.order_id = external.order_id"]


def test_an_authored_name_matching_two_relations_is_refused():
    dictionary = DataDictionary.model_validate(
        {"tables": [{"name": "orders", "description": "d"}]}
    )
    relations = {
        "A.PUBLIC.ORDERS": relation("A.PUBLIC.ORDERS", kind="table"),
        "B.PUBLIC.ORDERS": relation("B.PUBLIC.ORDERS", kind="table"),
    }
    with pytest.raises(ValueError, match="more than one"):
        merge_dictionary(
            dictionary,
            relations,
            describe_relation=lambda table_id: warehouse_columns(),
            identifier_case="upper",
        )


def test_two_authored_names_matching_one_relation_are_refused():
    dictionary = DataDictionary.model_validate(
        {
            "tables": [
                {"name": "orders", "description": "d"},
                {"name": "PUBLIC.ORDERS", "description": "d"},
            ]
        }
    )
    relations = {"A.PUBLIC.ORDERS": relation("A.PUBLIC.ORDERS", kind="table")}
    with pytest.raises(ValueError, match="both match"):
        merge_dictionary(
            dictionary,
            relations,
            describe_relation=lambda table_id: warehouse_columns(),
            identifier_case="upper",
        )


def test_an_exact_label_beats_a_case_insensitive_match():
    dictionary = DataDictionary.model_validate(
        {"tables": [{"name": "A.PUBLIC.ORDERS", "description": "d"}]}
    )
    relations = {
        "A.PUBLIC.ORDERS": relation("A.PUBLIC.ORDERS", kind="table"),
        "a.public.orders": relation("a.public.orders", kind="table"),
    }
    merged = merge_dictionary(
        dictionary,
        relations,
        describe_relation=lambda table_id: warehouse_columns(),
        identifier_case="upper",
    )
    assert merged.definition_bindings is not None
    assert merged.definition_bindings["tables"]["A.PUBLIC.ORDERS"] == "A.PUBLIC.ORDERS"


def test_a_dictionary_without_tables_is_returned_untouched():
    dictionary = DataDictionary.model_validate({})
    merged = merge_dictionary(
        dictionary, {}, describe_relation=lambda table_id: [], identifier_case="upper"
    )
    assert merged.definition_bindings is None


def test_a_rekeyed_table_still_shows_its_relationships():
    """The authored name is what the relationship prose says.

    After the merge re-keys `orders` to its warehouse label, a relationship
    written as `orders.order_id = ...` still has to reach the table's
    first-touch entry, or the join disappears from the prompt.
    """
    merged = merged_fixture()
    entry = merged.dictionary.entry_parts("ANALYTICS.PUBLIC.ORDERS", None)
    assert any("orders.order_id = external.order_id" in part for part in entry)


def test_an_explicitly_selected_table_that_is_missing_is_kept_for_validation():
    """A named table that the warehouse does not have must still be reported.

    Dropping it here turns "you asked for a table that is not there" into a
    silently smaller selection.
    """
    registry = table_registry(
        selectors=[Selector(catalog="main", schema="sales", table="absent")],
        exact_relation=lambda selector: None,
        list_relations=lambda selector: [],
    )
    assert list(registry.validate) == ["main.sales.absent"]
    assert registry.relations["main.sales.absent"].discovered is False


def test_an_explicitly_selected_table_that_exists_is_marked_discovered():
    registry = table_registry(
        selectors=[Selector(catalog="main", schema="sales", table="orders")],
        exact_relation=lambda selector: relation("main.sales.orders", kind="table"),
        list_relations=lambda selector: [],
    )
    assert registry.relations["main.sales.orders"].discovered is True
    assert list(registry.validate) == ["main.sales.orders"]


def test_an_excluded_explicit_selection_is_not_validated():
    registry = table_registry(
        selectors=[Selector(catalog="main", schema="sales", table="TMP_LOAD")],
        exact_relation=lambda selector: None,
        list_relations=lambda selector: [],
        exclude=["TMP_*"],
    )
    assert registry.validate == {}
    assert registry.relations == {}

"""Token expansion, the kind index, and grain metadata.

The registry consumes export records. These tests build records directly
rather than compiling them, which is the seam working as intended: the
registry is usable before the compiler exists and keeps working after it is
replaced by whatever data-dict eventually provides.
"""

import pytest

from commons._definitions import (
    ExportRecord,
    Registry,
    applied_text,
    context_chunks,
    entry_text,
    expand_tokens,
    index_overflows,
    index_text,
)
from commons._definitions._registry import _GROUPS as _GROUPS_FOR_TEST


def record(
    name: str,
    table: str = "sales",
    *,
    source: str = "sales_db",
    kind: str = "metric",
    sql: str = "sum(revenue)",
    label: str | None = None,
    description: str | None = None,
    mixed_grain: bool = False,
    definitions: list[str] | None = None,
    notes: list[str] | None = None,
) -> ExportRecord:
    return ExportRecord(
        name=name,
        table=table,
        source=source,
        kind=kind,
        type="number",
        expression="SUM(revenue)",
        label=label,
        description=description,
        details=None,
        columns=["revenue"],
        definitions=definitions or [],
        sql=sql,
        target="SQL(duckdb)",
        notes=notes or [],
        mixed_grain=mixed_grain,
    )


# ---- token expansion -----------------------------------------------------


def test_a_bare_token_expands_to_parenthesized_sql() -> None:
    sql, applied = expand_tokens(
        "SELECT {{net_revenue}} FROM sales", [record("net_revenue")]
    )

    assert sql == "SELECT (sum(revenue)) FROM sales"
    assert [item.name for item in applied] == ["net_revenue"]


def test_whitespace_inside_a_token_is_tolerated() -> None:
    sql, _ = expand_tokens(
        "SELECT {{  net_revenue  }} FROM sales", [record("net_revenue")]
    )

    assert sql == "SELECT (sum(revenue)) FROM sales"


def test_sql_without_tokens_passes_through_untouched() -> None:
    sql, applied = expand_tokens("SELECT 1 FROM sales", [record("net_revenue")])

    assert sql == "SELECT 1 FROM sales"
    assert applied == []


def test_a_qualified_token_selects_the_named_table() -> None:
    records = [
        record("total", table="sales", sql="sum(a)"),
        record("total", table="returns", sql="sum(b)"),
    ]

    sql, _ = expand_tokens("SELECT {{sales::total}} FROM sales JOIN returns", records)

    assert sql == "SELECT (sum(a)) FROM sales JOIN returns"


def test_a_bare_token_scopes_to_the_table_the_query_names() -> None:
    records = [
        record("total", table="sales", sql="sum(a)"),
        record("total", table="returns", sql="sum(b)"),
    ]

    sql, _ = expand_tokens("SELECT {{total}} FROM returns", records)

    assert sql == "SELECT (sum(b)) FROM returns"


def test_an_ambiguous_bare_token_says_how_to_qualify_it() -> None:
    records = [record("total", table="sales"), record("total", table="returns")]

    with pytest.raises(ValueError) as caught:
        expand_tokens("SELECT {{total}} FROM sales JOIN returns", records)

    assert "{{sales::total}}" in str(caught.value)
    assert "{{returns::total}}" in str(caught.value)


def test_a_token_whose_table_is_absent_from_the_query_errors() -> None:
    with pytest.raises(ValueError, match="does not appear in this query"):
        expand_tokens("SELECT {{net_revenue}} FROM other", [record("net_revenue")])


def test_an_unknown_token_lists_what_is_available() -> None:
    with pytest.raises(ValueError) as caught:
        expand_tokens("SELECT {{nope}} FROM sales", [record("net_revenue")])

    assert "{{net_revenue}} (sales)" in str(caught.value)


def test_an_unknown_token_against_no_definitions_says_so() -> None:
    with pytest.raises(ValueError, match="no governed definitions"):
        expand_tokens("SELECT {{nope}} FROM sales", [])


def test_a_dotted_token_is_read_as_table_qualified() -> None:
    sql, _ = expand_tokens(
        "SELECT {{sales.net_revenue}} FROM sales", [record("net_revenue")]
    )

    assert sql == "SELECT (sum(revenue)) FROM sales"


def test_a_definition_name_may_contain_spaces() -> None:
    sql, _ = expand_tokens(
        "SELECT {{net revenue}} FROM sales", [record("net revenue", sql="sum(x)")]
    )

    assert sql == "SELECT (sum(x)) FROM sales"


def test_backslashes_in_expanded_sql_survive() -> None:
    escaped = record("pattern", sql=r"regexp_matches(x, '\d+')")

    sql, _ = expand_tokens("SELECT {{pattern}} FROM sales", [escaped])

    assert sql == r"SELECT (regexp_matches(x, '\d+')) FROM sales"


def test_the_same_token_twice_expands_both_occurrences() -> None:
    sql, applied = expand_tokens(
        "SELECT {{total}}, {{total}} FROM sales", [record("total", sql="sum(a)")]
    )

    assert sql == "SELECT (sum(a)), (sum(a)) FROM sales"
    assert len(applied) == 1


# ---- the prompt index ----------------------------------------------------


def test_the_index_groups_definitions_by_table_and_kind() -> None:
    registry = Registry(
        [
            record("net_revenue", kind="metric"),
            record("is_emea", kind="filter"),
            record("list_price", kind="derived"),
        ]
    )

    assert index_text(registry) == (
        "- sales: filters `{{is_emea}}`; derived `{{list_price}}`; "
        "metrics `{{net_revenue}}`"
    )


def test_a_label_is_the_index_hint() -> None:
    registry = Registry([record("is_emea", kind="filter", label="EMEA segment")])

    assert index_text(registry) == "- sales: filters `{{is_emea}}` (EMEA segment)"


def test_the_index_scopes_by_source_when_there_are_several() -> None:
    registry = Registry(
        [record("a", source="one"), record("b", source="two", table="other")]
    )

    text = index_text(registry)

    assert "- one.sales:" in text
    assert "- two.other:" in text


def test_the_index_is_capped_and_reports_its_overflow() -> None:
    registry = Registry([record(f"filter_{i:03d}", kind="filter") for i in range(400)])

    assert index_overflows(registry)
    # One line per table, so a roster this size is a single long line: the cap
    # drops it entirely rather than truncating mid-token.
    assert index_text(registry) == ""
    assert not index_overflows(registry, cap_chars=100_000)
    assert "filter_399" in index_text(registry, cap_chars=100_000)


def test_an_empty_registry_has_an_empty_index() -> None:
    assert index_text(Registry([])) == ""
    assert not index_overflows(Registry([]))


# ---- rendering -----------------------------------------------------------


def test_first_touch_shows_compiled_sql_and_not_the_expression() -> None:
    text = entry_text([record("net_revenue", sql="sum(revenue)")])

    assert text is not None
    assert "Governed definitions" in text
    assert "`{{net_revenue}}`" in text
    assert "Selected SQL(duckdb)" in text
    assert "SUM(revenue)" not in text


def test_first_touch_carries_translation_notes() -> None:
    text = entry_text([record("remainder", notes=["integer modulus by zero differs"])])

    assert text is not None
    assert "Translation notes: integer modulus by zero differs" in text


def test_first_touch_is_none_without_definitions() -> None:
    assert entry_text([]) is None


def test_definitions_are_indexed_as_context_chunks() -> None:
    # A retrieved chunk has to say what the token expands to, or retrieval
    # surfaces a name the model cannot use.
    chunks = context_chunks([record("net_revenue", sql="sum(revenue)")])

    assert len(chunks) == 1
    assert chunks[0].startswith(
        "Governed definition `{{net_revenue}}` on table `sales` (metric, number)"
    )
    assert "Selected SQL(duckdb): `(sum(revenue))`." in chunks[0]


def test_a_context_chunk_shows_compiled_sql_and_not_the_expression() -> None:
    chunks = context_chunks([record("net_revenue", sql="sum(revenue)")])

    assert "SUM(revenue)" not in chunks[0]


def test_a_context_chunk_carries_translation_notes() -> None:
    chunks = context_chunks([record("remainder", notes=["modulus by zero differs"])])

    assert "Translation notes: modulus by zero differs" in chunks[0]


def test_applied_text_reports_the_sql_each_token_became() -> None:
    text = applied_text([record("net_revenue", sql="sum(revenue)")])

    assert text is not None
    assert "- {{net_revenue}} (sales): SQL(duckdb) `(sum(revenue))`" in text


def test_applied_text_is_none_when_nothing_expanded() -> None:
    assert applied_text([]) is None


# ---- grain and construction ----------------------------------------------


def test_grain_metadata_rides_on_the_record() -> None:
    # call_metrics' mixed-grain guard reads this and nothing else; the shape
    # that produced it stays behind the seam.
    assert record("net_revenue", mixed_grain=True).mixed_grain is True


def test_definitions_on_an_unexposed_table_fail_construction() -> None:
    from commons import _duckdb
    from commons._backends import DuckDBBackend
    from commons._data_dictionary import DataDictionary, Table
    from commons._data_source import DataSource
    from commons._definitions import build_registry

    dictionary = DataDictionary(tables={"ghost": Table()})
    dictionary.tables["ghost"].compiled_definitions = [record("total", table="ghost")]
    source = DataSource(
        backend=DuckDBBackend(_duckdb.connect()),
        tables=["sales"],
        dictionary=dictionary,
    )

    with pytest.raises(ValueError, match="ghost"):
        build_registry({"sales_db": source})


def test_the_registry_labels_records_with_their_source() -> None:
    from commons import _duckdb
    from commons._backends import DuckDBBackend
    from commons._data_dictionary import DataDictionary, Table
    from commons._data_source import DataSource
    from commons._definitions import build_registry

    dictionary = DataDictionary(tables={"sales": Table()})
    dictionary.tables["sales"].compiled_definitions = [record("total", source="")]
    source = DataSource(
        backend=DuckDBBackend(_duckdb.connect()),
        tables=["sales"],
        dictionary=dictionary,
    )

    registry = build_registry({"sales_db": source})

    assert [item.source for item in registry.records] == ["sales_db"]
    assert registry.for_source("nope") == []


def test_an_empty_source_set_builds_an_empty_registry() -> None:
    from commons._definitions import build_registry

    assert build_registry({}).records == []


# ---- against the shared contract -----------------------------------------
#
# The first Python code to consume the definitions contract. The compiler does
# not exist yet, so these read records data-dict itself produced, which is
# what the registry will consume either way.


def fixture_records() -> list[ExportRecord]:
    from ._shared import load_shared_fixture

    spec = load_shared_fixture("definitions")
    records = []
    for name, cases in spec["export_records"].items():
        for key, payload in cases.items():
            table, _, definition = key.partition("::")
            translation = payload["translation"]
            records.append(
                ExportRecord(
                    name=definition,
                    table=table,
                    source=name,
                    kind=payload["kind"],
                    type=payload["type"],
                    expression=payload["expression"],
                    label=None,
                    description=None,
                    details=None,
                    columns=list(payload["columns"]),
                    definitions=list(payload["definitions"]),
                    sql=translation["code"],
                    target=translation["target"],
                    notes=list(translation["notes"]),
                    mixed_grain=spec["mixed_grain"][name][key],
                )
            )
    return records


def test_the_fixture_yields_records() -> None:
    assert len(fixture_records()) > 0


def test_every_fixture_definition_expands_to_its_compiled_sql() -> None:
    for item in fixture_records():
        sql, applied = expand_tokens(
            f"SELECT {{{{{item.table}::{item.name}}}}} FROM {item.table}", [item]
        )

        assert sql == f"SELECT ({item.sql}) FROM {item.table}", item.name
        assert applied == [item]


def test_every_fixture_kind_is_one_the_index_groups() -> None:
    # An unrecognised kind would silently vanish from the prompt index.
    for item in fixture_records():
        assert item.kind in _GROUPS_FOR_TEST, item.name


def test_the_index_renders_every_fixture_definition() -> None:
    registry = Registry(fixture_records())

    text = index_text(registry, cap_chars=1_000_000)

    for item in registry.records:
        assert f"`{{{{{item.name}}}}}`" in text, item.name


def test_first_touch_renders_every_fixture_definition() -> None:
    records = fixture_records()
    text = entry_text(records)

    assert text is not None
    for item in records:
        assert f"`{{{{{item.name}}}}}`" in text, item.name


def test_a_typeless_definition_omits_the_type_rather_than_naming_it() -> None:
    # data-dict omits `type` when no single one is inferred. Printing the
    # language's null spelling would put "None" in the prompt, so the type is
    # left out and the rest of the gist still reaches the model.
    typeless = [item for item in fixture_records() if item.type is None]
    assert len(typeless) == 1

    chunk = context_chunks(typeless)[0]

    assert "None" not in chunk
    assert "(derived)" in chunk
    assert "Selected SQL(duckdb)" in chunk


def test_grain_metadata_reaches_the_records() -> None:
    mixed = [item for item in fixture_records() if item.mixed_grain]

    assert mixed
    assert not all(item.mixed_grain for item in fixture_records())


def test_an_expansion_cannot_widen_scope_for_a_later_token() -> None:
    # Compiled SQL can name a table the query does not. Resolving later tokens
    # against already-expanded text would let that count as the table being
    # present, which is the check that keeps a token bound to its own table.
    records = [
        record("total", table="sales", sql="sum(returns.x)"),
        record("other", table="returns", sql="count(*)"),
    ]

    with pytest.raises(ValueError, match="does not appear in this query"):
        expand_tokens("SELECT {{sales::total}}, {{other}} FROM sales", records)


def test_the_index_cap_counts_the_lines_it_joins() -> None:
    registry = Registry(
        [record(f"d{i}", table=f"t{i}", kind="metric") for i in range(30)]
    )

    assert len(index_text(registry, cap_chars=300)) <= 300

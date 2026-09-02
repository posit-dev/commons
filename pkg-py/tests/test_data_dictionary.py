"""Reading data-dict.yaml and rendering its three channels."""

from pathlib import Path

import pytest

from commons._data_dictionary import DataDictionary, as_data_dictionary

RETAIL = """
name: retail sales
description: Order and revenue data for a small retailer.
details: Rows are order lines, not orders.
tables:
  - name: sales
    description: One row per order line.
    details: Cancelled lines are retained.
    columns:
      - name: revenue
        type: number(quantity)
        units: USD
        description: Line revenue.
      - name: region
        type: enum
        values: [Americas, APAC, EMEA]
      - name: status
        type: string
        nullable: false
        values: {O: Open, C: Closed}
        examples: [O, C]
      - name: score
        type: number
        range: [0, 100]
  - name: regions
    description: One row per sales region.
relationships:
  - join: sales.region = regions.name
    cardinality: many-to-one
    description: Each sales line belongs to one region.
glossary:
  ARR: Annual recurring revenue.
  churn: A customer who stopped buying.
"""


@pytest.fixture
def retail(tmp_path: Path) -> DataDictionary:
    path = tmp_path / "data-dict.yaml"
    path.write_text(RETAIL, encoding="utf-8")
    return DataDictionary.from_path(path)


# ---- reading -------------------------------------------------------------


def test_tables_and_columns_are_keyed_by_name(retail: DataDictionary) -> None:
    assert list(retail.tables) == ["sales", "regions"]
    assert list(retail.tables["sales"].columns) == [
        "revenue",
        "region",
        "status",
        "score",
    ]


def test_a_pre_keyed_mapping_is_accepted(tmp_path: Path) -> None:
    path = tmp_path / "d.yaml"
    path.write_text(
        "tables:\n  sales:\n    columns:\n      revenue:\n        type: number\n",
        encoding="utf-8",
    )
    dictionary = DataDictionary.from_path(path)

    assert list(dictionary.tables) == ["sales"]
    assert list(dictionary.tables["sales"].columns) == ["revenue"]


def test_a_table_without_a_name_errors(tmp_path: Path) -> None:
    path = tmp_path / "d.yaml"
    path.write_text("tables:\n  - description: no name here\n", encoding="utf-8")

    with pytest.raises(ValueError, match="name"):
        DataDictionary.from_path(path)


def test_a_column_without_a_name_errors(tmp_path: Path) -> None:
    path = tmp_path / "d.yaml"
    path.write_text(
        "tables:\n  - name: sales\n    columns:\n      - type: number\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="column"):
        DataDictionary.from_path(path)


def test_unknown_fields_and_missing_sections_are_tolerated(tmp_path: Path) -> None:
    path = tmp_path / "d.yaml"
    path.write_text(
        "$version: '0.1.0'\nwhat: ever\ntables:\n  - name: t\n    fancy: yes\n",
        encoding="utf-8",
    )
    dictionary = DataDictionary.from_path(path)

    assert list(dictionary.tables) == ["t"]
    assert dictionary.glossary == {}


def test_a_typed_column_missing_its_range_is_not_an_error(
    retail: DataDictionary,
) -> None:
    # The reader ignores the parts of the spec it never inspects.
    assert retail.tables["sales"].columns["revenue"].range is None


def test_an_empty_file_reads_as_an_empty_dictionary(tmp_path: Path) -> None:
    path = tmp_path / "d.yaml"
    path.write_text("", encoding="utf-8")

    assert DataDictionary.from_path(path).tables == {}


def test_multi_line_prose_is_kept_as_authored(tmp_path: Path) -> None:
    # Prose reaches the model verbatim, so it stays markdown.
    path = tmp_path / "d.yaml"
    path.write_text(
        "description: |\n  First line.\n\n  Second line.\ntables: []\n",
        encoding="utf-8",
    )

    assert DataDictionary.from_path(path).description == (
        "First line.\n\nSecond line.\n"
    )


def test_as_data_dictionary_accepts_a_path_or_none(tmp_path: Path) -> None:
    path = tmp_path / "data-dict.yaml"
    path.write_text(RETAIL, encoding="utf-8")

    assert as_data_dictionary(None) is None
    assert isinstance(as_data_dictionary(str(path)), DataDictionary)
    parsed = as_data_dictionary(DataDictionary.from_path(path))
    assert parsed is not None
    assert parsed.name == "retail sales"


def test_as_data_dictionary_rejects_other_input() -> None:
    with pytest.raises(TypeError, match="path"):
        as_data_dictionary(42)


def test_a_missing_file_names_the_path(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError, match="nope.yaml"):
        as_data_dictionary(str(tmp_path / "nope.yaml"))


# ---- channel 1: always in the prompt -------------------------------------


def test_ambient_text_carries_the_dictionary_prose(retail: DataDictionary) -> None:
    text = retail.ambient_prompt_text()

    assert "Order and revenue data for a small retailer." in text
    assert "Rows are order lines, not orders." in text


def test_ambient_text_is_empty_without_prose(tmp_path: Path) -> None:
    path = tmp_path / "d.yaml"
    path.write_text("tables:\n  - name: sales\n", encoding="utf-8")

    assert DataDictionary.from_path(path).ambient_prompt_text() == ""


def test_ambient_glossary_terms_respect_the_cap(retail: DataDictionary) -> None:
    # "ARR" plus its body is 28 characters, so 28 admits it and 27 does not.
    assert retail.ambient_glossary_terms() == ["ARR", "churn"]
    assert retail.ambient_glossary_terms(cap_chars=28) == ["ARR"]
    assert retail.ambient_glossary_terms(cap_chars=27) == []


# ---- channel 2: first touch ----------------------------------------------


def test_entry_text_documents_a_tables_columns(retail: DataDictionary) -> None:
    text = retail.entry_text("sales")

    assert text is not None
    assert text.startswith("Dictionary entry for `sales`:")
    assert "One row per order line." in text
    assert "- revenue (number(quantity), USD): Line revenue." in text


def test_entry_text_renders_column_facts(retail: DataDictionary) -> None:
    text = retail.entry_text("sales")

    assert text is not None
    assert "Values: Americas, APAC, EMEA." in text
    assert "O (Open), C (Closed)" in text
    assert "not nullable" in text
    assert "Range: 0 to 100." in text
    assert "Examples: O, C." in text


def test_entry_text_includes_relationships_that_mention_the_table(
    retail: DataDictionary,
) -> None:
    text = retail.entry_text("sales")

    assert text is not None
    assert "Relationships:" in text
    assert "sales.region = regions.name (many-to-one)" in text


def test_entry_text_omits_relationships_that_do_not_mention_the_table(
    tmp_path: Path,
) -> None:
    path = tmp_path / "d.yaml"
    path.write_text(
        "tables:\n  - name: sales\n  - name: other\n"
        "relationships:\n  - join: other.a = elsewhere.b\n",
        encoding="utf-8",
    )
    dictionary = DataDictionary.from_path(path)

    text = dictionary.entry_text("sales")

    assert text is not None
    assert "Relationships:" not in text


def test_entry_text_is_none_for_an_undocumented_table(retail: DataDictionary) -> None:
    assert retail.entry_text("nope") is None


def test_terms_past_the_ambient_cap_are_co_resolved_at_first_touch(
    tmp_path: Path,
) -> None:
    path = tmp_path / "d.yaml"
    path.write_text(
        "tables:\n"
        "  - name: sales\n"
        "    description: Revenue by churn cohort.\n"
        "glossary:\n"
        "  ARR: Annual recurring revenue.\n"
        "  churn: A customer who stopped buying.\n",
        encoding="utf-8",
    )
    dictionary = DataDictionary.from_path(path)

    assert dictionary.ambient_glossary_terms(cap_chars=30) == ["ARR"]
    past_cap = dictionary.entry_text("sales", ambient_cap_chars=30)
    assert past_cap is not None
    assert "Definitions:" in past_cap
    assert "churn: A customer who stopped buying." in past_cap


def test_a_term_already_in_the_prompt_is_not_repeated_at_first_touch(
    tmp_path: Path,
) -> None:
    path = tmp_path / "d.yaml"
    path.write_text(
        "tables:\n"
        "  - name: sales\n"
        "    description: Revenue by churn cohort.\n"
        "glossary:\n"
        "  churn: A customer who stopped buying.\n",
        encoding="utf-8",
    )
    dictionary = DataDictionary.from_path(path)

    text = dictionary.entry_text("sales")

    assert text is not None
    assert "Definitions:" not in text


# ---- channel 3: the search index -----------------------------------------


def test_context_chunks_cover_dictionary_prose_tables_and_glossary(
    retail: DataDictionary,
) -> None:
    chunks = retail.context_chunks()

    assert "Rows are order lines, not orders." in chunks
    assert any(chunk.startswith("Table `sales`:") for chunk in chunks)
    assert "ARR: Annual recurring revenue." in chunks


def test_context_chunks_skip_tables_with_no_prose(tmp_path: Path) -> None:
    # Column-level content stays out of the store: first touch owns it, and
    # indexing it would pay for a second copy the agent already has.
    path = tmp_path / "d.yaml"
    path.write_text(
        "tables:\n  - name: bare\n    columns:\n      - name: x\n        type: number\n",
        encoding="utf-8",
    )
    dictionary = DataDictionary.from_path(path)

    assert dictionary.context_chunks() == []


def test_context_chunks_do_not_carry_column_level_content(
    retail: DataDictionary,
) -> None:
    assert not any("Line revenue." in chunk for chunk in retail.context_chunks())


# ---- wiring into data_source() -------------------------------------------


def test_data_source_accepts_a_dictionary_path(tmp_path: Path) -> None:
    import pandas as pd

    from commons import data_source

    path = tmp_path / "data-dict.yaml"
    path.write_text(RETAIL, encoding="utf-8")
    source = data_source(sales=pd.DataFrame({"revenue": [1.0]}), dictionary=str(path))

    assert source.dictionary is not None
    assert source.dictionary.name == "retail sales"


def test_data_source_rejects_other_dictionary_input() -> None:
    import pandas as pd

    from commons import data_source

    with pytest.raises(TypeError, match="path"):
        data_source(sales=pd.DataFrame({"revenue": [1.0]}), dictionary=42)


def test_a_source_without_a_dictionary_has_none() -> None:
    import pandas as pd

    from commons import data_source

    assert data_source(sales=pd.DataFrame({"revenue": [1.0]})).dictionary is None


def test_a_frame_named_dictionary_fails_loudly_rather_than_silently() -> None:
    # `dictionary` applies to every source form, so unlike `tables` it cannot
    # double as a frame name. The failure must be named, not a silent drop.
    import pandas as pd

    from commons import data_source

    with pytest.raises(TypeError, match="DataFrame"):
        data_source(dictionary=pd.DataFrame({"revenue": [1.0]}))

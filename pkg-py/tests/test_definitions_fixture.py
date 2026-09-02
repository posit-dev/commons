"""The definitions contract both packages consume.

This checks the fixture's own integrity: that it covers the corpus, that its
sections agree with each other, and that it is not empty. Running the cases
against an implementation comes with the registry and the compiler.
"""

from typing import Any

import yaml

from ._shared import SHARED_DIR, load_shared_fixture

SPEC = load_shared_fixture("definitions")
CORPUS = SHARED_DIR / SPEC["corpus_dir"]
EXPORTS: dict[str, dict[str, Any]] = SPEC["export_records"]


def test_the_fixture_is_not_empty() -> None:
    # An empty fixture would collect zero cases and every runner would pass.
    assert EXPORTS
    assert sum(len(cases) for cases in EXPORTS.values()) > 0
    assert SPEC["invalid"]


def test_every_valid_corpus_file_has_records() -> None:
    on_disk = {path.name for path in (CORPUS / "valid").glob("*.yaml")}

    assert on_disk == set(EXPORTS)


def test_every_invalid_corpus_file_has_an_error_code() -> None:
    on_disk = {path.name for path in (CORPUS / "invalid").glob("*.yaml")}

    assert on_disk == set(SPEC["invalid"])


def test_grain_metadata_covers_every_exported_definition() -> None:
    for name, cases in EXPORTS.items():
        assert set(SPEC["mixed_grain"][name]) == set(cases), name


def test_grain_metadata_pins_at_least_one_mixed_case() -> None:
    # All-false grain would pin nothing: the guard it feeds would look correct
    # while never having been exercised.
    values = [
        value for cases in SPEC["mixed_grain"].values() for value in cases.values()
    ]
    assert any(values)
    assert not all(values)


def test_every_record_carries_a_duckdb_translation() -> None:
    for cases in EXPORTS.values():
        for key, record in cases.items():
            assert record["translation"]["target"] == "SQL(duckdb)", key
            assert record["translation"]["code"], key
            assert record["kind"] in {"metric", "filter", "derived"}, key


def test_every_record_names_the_expression_it_came_from() -> None:
    for cases in EXPORTS.values():
        for key, record in cases.items():
            assert record["expression"], key


def test_a_definition_with_no_single_inferred_type_carries_none() -> None:
    # data-dict omits `type` when an expression infers no single one, such as
    # a CASE over both a date and a datetime column. Pinned because the
    # obvious implementation invents a type instead of leaving it out.
    typeless = {
        key
        for cases in EXPORTS.values()
        for key, record in cases.items()
        if record["type"] is None
    }

    assert "survey::mixed temporal case" in typeless
    assert all(
        record["type"] is None or isinstance(record["type"], str)
        for cases in EXPORTS.values()
        for record in cases.values()
    )


def test_records_match_the_definitions_authored_in_the_corpus() -> None:
    # The fixture is generated, so this catches a stale copy rather than a
    # wrong one: a definition added to the corpus without regenerating.
    for name, cases in EXPORTS.items():
        document = yaml.safe_load(
            (CORPUS / "valid" / name).read_text(encoding="utf-8")
        )
        authored = {
            f"{table['name']}::{definition['name']}"
            for table in document.get("tables", [])
            for definition in table.get("definitions") or []
        }
        assert authored == set(cases), name


def test_referenced_definitions_resolve_within_their_fixture() -> None:
    for name, cases in EXPORTS.items():
        names = {key.split("::", 1)[1] for key in cases}
        for key, record in cases.items():
            for referenced in record["definitions"]:
                assert referenced in names, f"{name} {key} -> {referenced}"

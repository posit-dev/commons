"""Type checking, kind inference, and reference resolution.

The authority is `tests/shared/definitions.json`, generated from the pinned
data-dict binary. These tests assert the fields that exist before the emitter
lands: `kind`, `type`, `columns` and `definitions`. Translations arrive with
`_emit_duckdb`.
"""

import json
import shutil
import subprocess

import pytest
import yaml

from commons._definitions._export import DefinitionExport, export_spec
from tests._shared import SHARED_DIR, load_shared_fixture


def spec(*definitions: dict, columns: list[dict] | None = None) -> dict:
    """A one-table dictionary in data-dict's YAML shape."""
    return {
        "tables": [
            {
                "name": "orders",
                "columns": columns
                if columns is not None
                else [
                    {"name": "amount", "type": "number(quantity)"},
                    {"name": "region", "type": "string"},
                    {"name": "created", "type": "date"},
                    {"name": "shipped", "type": "datetime"},
                    {"name": "paid", "type": "boolean"},
                ],
                "definitions": list(definitions),
            }
        ]
    }


def one(expr: str, name: str = "d", **extra) -> DefinitionExport:
    return export_spec(spec({"name": name, "expr": expr, **extra}))[
        "orders"
    ].definitions[name]


# --- kind inference -------------------------------------------------------


def test_a_boolean_row_expression_is_a_filter():
    assert one("amount > 0").kind == "filter"


def test_an_aggregate_is_a_metric():
    assert one("sum(amount)").kind == "metric"


def test_a_constant_is_a_metric():
    # Shape `const` is a metric too: it needs no grouping to evaluate.
    assert one("1 + 1").kind == "metric"


def test_a_non_boolean_row_expression_is_derived():
    assert one("amount * 2").kind == "derived"


# --- type inference -------------------------------------------------------


@pytest.mark.parametrize(
    ("expr", "expected"),
    [
        ("amount > 0", "boolean"),
        ("amount * 2", "number"),
        ("lower(region)", "string"),
        ("sum(amount)", "number"),
        ("created", "date"),
        ("shipped", "datetime"),
        ("now()", "datetime"),
    ],
)
def test_the_inferred_type_is_exported(expr: str, expected: str):
    assert one(expr).type == expected


def test_an_untyped_column_has_no_inferred_type_and_is_refused():
    with pytest.raises(ValueError, match="no inferred type"):
        export_spec(
            spec(
                {"name": "d", "expr": "mystery"},
                columns=[{"name": "mystery"}],
            )
        )


def test_a_null_literal_exports_without_a_type():
    # `any` is a type, so it is not refused; it simply has nothing to export.
    assert one("null").type is None


# --- column descriptors ---------------------------------------------------


@pytest.mark.parametrize(
    ("declared", "expr", "expected"),
    [
        ("number(quantity)", "c > 1", "boolean"),
        ("enum", "c", "string"),
        ("string", "c", "string"),
        ("boolean", "c", "boolean"),
        ("DATE", "c", "date"),
    ],
)
def test_declared_column_types_map_to_expression_types(
    declared: str, expr: str, expected: str
):
    result = export_spec(
        spec({"name": "d", "expr": expr}, columns=[{"name": "c", "type": declared}])
    )
    assert result["orders"].definitions["d"].type == expected


def test_an_unsupported_column_type_is_refused():
    with pytest.raises(ValueError, match="unsupported type"):
        export_spec(
            spec({"name": "d", "expr": "c"}, columns=[{"name": "c", "type": "blob"}])
        )


def test_a_struct_field_can_be_referenced_through_a_dotted_path():
    result = export_spec(
        spec(
            {"name": "d", "expr": "payload.total > 0"},
            columns=[
                {
                    "name": "payload",
                    "type": "struct",
                    "fields": [{"name": "total", "type": "number"}],
                }
            ],
        )
    )
    assert result["orders"].definitions["d"].columns == ["payload.total"]


def test_a_missing_struct_field_is_refused():
    with pytest.raises(ValueError, match="no field"):
        export_spec(
            spec(
                {"name": "d", "expr": "payload.missing"},
                columns=[
                    {
                        "name": "payload",
                        "type": "struct",
                        "fields": [{"name": "total", "type": "number"}],
                    }
                ],
            )
        )


def test_a_list_element_cannot_be_referenced():
    with pytest.raises(ValueError, match="list"):
        export_spec(
            spec(
                {"name": "d", "expr": "tags.first"},
                columns=[{"name": "tags", "type": "list(string)"}],
            )
        )


# --- references and ordering ----------------------------------------------


def test_direct_column_references_are_collected_in_order():
    assert one("amount > 0 and region = 'x'").columns == ["amount", "region"]


def test_a_repeated_column_is_listed_once():
    assert one("amount > 0 and amount < 10").columns == ["amount"]


def test_a_sibling_definition_is_a_definition_reference_not_a_column():
    result = export_spec(
        spec(
            {"name": "big", "expr": "amount > 100"},
            {"name": "d", "expr": "big and region = 'x'"},
        )
    )
    record = result["orders"].definitions["d"]
    assert record.definitions == ["big"]
    assert record.columns == ["region"]


def test_a_definition_may_be_declared_before_the_one_it_uses():
    # Resolution order follows the dependency graph, not the authored order.
    result = export_spec(
        spec(
            {"name": "d", "expr": "big and region = 'x'"},
            {"name": "big", "expr": "amount > 100"},
        )
    )
    assert result["orders"].definitions["d"].definitions == ["big"]


def test_definitions_that_reference_each_other_are_refused():
    with pytest.raises(ValueError, match="cycle"):
        export_spec(
            spec(
                {"name": "a", "expr": "b"},
                {"name": "b", "expr": "a"},
            )
        )


def test_an_unknown_column_is_refused():
    with pytest.raises(ValueError, match="not found"):
        one("nope > 1")


def test_a_definition_may_not_shadow_a_column():
    with pytest.raises(ValueError, match="share names with columns"):
        export_spec(spec({"name": "amount", "expr": "1"}))


def test_a_duplicate_definition_name_is_refused():
    with pytest.raises(ValueError, match="[Dd]uplicate"):
        export_spec(spec({"name": "d", "expr": "1"}, {"name": "d", "expr": "2"}))


def test_a_definition_needs_a_non_empty_expression():
    with pytest.raises(ValueError, match="expr"):
        export_spec(spec({"name": "d", "expr": "  "}))


def test_a_non_string_label_is_refused():
    with pytest.raises(ValueError, match="label"):
        export_spec(spec({"name": "d", "expr": "1", "label": 3}))


# --- type errors ----------------------------------------------------------


def test_comparing_a_string_with_a_number_is_refused():
    with pytest.raises(ValueError, match="Cannot compare"):
        one("region > 1")


def test_not_on_a_number_is_refused():
    with pytest.raises(ValueError, match="NOT"):
        one("not amount")


def test_arithmetic_on_a_string_is_refused():
    with pytest.raises(ValueError, match="arithmetic"):
        one("region + 1")


def test_an_unknown_function_is_refused():
    with pytest.raises(ValueError, match="Unknown function"):
        one("nonesuch(amount)")


def test_a_function_called_with_the_wrong_arity_is_refused():
    with pytest.raises(ValueError, match="argument"):
        one("lower(region, region)")


def test_an_aggregate_of_an_aggregate_is_refused():
    with pytest.raises(ValueError, match="already aggregated"):
        one("sum(sum(amount))")


def test_an_aggregate_through_a_sibling_definition_is_refused():
    with pytest.raises(ValueError, match="already aggregated"):
        export_spec(
            spec(
                {"name": "total", "expr": "sum(amount)"},
                {"name": "d", "expr": "sum(total)"},
            )
        )


def test_an_unknown_interval_unit_is_refused():
    with pytest.raises(ValueError, match="interval unit"):
        one("shipped > now() - interval(1, fortnights)")


# --- temporal coercion ----------------------------------------------------


def test_a_date_shaped_string_compares_against_a_date_column():
    assert one("created >= '2020-01-01'").type == "boolean"


def test_a_string_that_is_not_a_date_does_not_coerce():
    with pytest.raises(ValueError, match="Cannot compare"):
        one("created >= 'not-a-date'")


def test_a_datetime_string_compares_against_a_datetime_column():
    assert one("shipped >= '2020-01-01T00:00:00Z'").type == "boolean"


# --- COLUMNS selections ---------------------------------------------------


def test_a_columns_selection_over_a_bracket_list_type_checks():
    assert one("columns([paid]) = true").kind == "filter"


def test_a_columns_selection_naming_a_missing_column_is_refused():
    with pytest.raises(ValueError, match="not found"):
        one("columns([nope]) = true")


def test_a_columns_selection_outside_a_filter_is_refused():
    with pytest.raises(ValueError, match="boolean filter"):
        one("columns([amount]) + 1")


def test_two_columns_selections_in_one_expression_are_refused():
    with pytest.raises(ValueError, match="at most one|more than one"):
        one("columns([paid]) = true and columns([paid]) = false")


def test_a_regex_selection_collects_the_columns_it_matched():
    record = export_spec(
        spec(
            {"name": "d", "expr": "columns('^flag_') = true"},
            columns=[
                {"name": "flag_a", "type": "boolean"},
                {"name": "flag_b", "type": "boolean"},
                {"name": "other", "type": "boolean"},
            ],
        )
    )["orders"].definitions["d"]
    assert record.columns == ["flag_a", "flag_b"]


# --- regex validation -----------------------------------------------------


@pytest.mark.parametrize("pattern", ["(?=x)", "(?!x)", "(?<=x)", r"(a)\1"])
def test_patterns_rust_regex_cannot_compile_are_refused(pattern: str):
    # data-dict validates against Rust's `regex`, which has neither lookaround
    # nor backreferences. Python's `re` accepts all of these.
    with pytest.raises(ValueError, match="regular expression"):
        one(f"region similar to '{pattern}'")


def test_a_plain_pattern_is_accepted():
    assert one("region similar to '^EMEA'").type == "boolean"


# --- the shared corpus ----------------------------------------------------


def _corpus(kind: str):
    return sorted((SHARED_DIR / "definition-export" / kind).glob("*.yaml"))


def test_the_export_matches_the_shared_contract():
    fixture = load_shared_fixture("definitions")["export_records"]
    paths = _corpus("valid")
    assert paths, "the shared corpus is empty"
    checked = 0
    for path in paths:
        exported = export_spec(yaml.safe_load(path.read_text(encoding="utf-8")))
        expected = fixture[path.name]
        for key, case in expected.items():
            table, name = key.split("::")
            record = exported[table].definitions[name]
            assert record.expression == case["expression"], key
            assert record.kind == case["kind"], key
            assert record.type == case["type"], key
            assert record.columns == case["columns"], key
            assert record.definitions == case["definitions"], key
            checked += 1
    assert checked == 42


def test_every_invalid_corpus_fixture_is_refused():
    paths = _corpus("invalid")
    assert len(paths) == 11
    for path in paths:
        with pytest.raises(ValueError):
            export_spec(yaml.safe_load(path.read_text(encoding="utf-8")))


# --- agreement with a live data-dict binary --------------------------------

DATA_DICT = shutil.which("data-dict")
needs_binary = pytest.mark.skipif(
    DATA_DICT is None, reason="the data-dict CLI is not installed"
)


def _run(*args: str) -> subprocess.CompletedProcess[str]:
    assert DATA_DICT is not None
    return subprocess.run(
        [DATA_DICT, *args], capture_output=True, text=True, check=False
    )


@needs_binary
def test_the_local_export_agrees_with_an_installed_data_dict():
    """The binary is the authority, not the fixture and not the R package."""
    paths = _corpus("valid")
    assert paths
    for path in paths:
        result = _run("export-spec", str(path))
        assert result.returncode == 0, result.stderr
        upstream = json.loads(result.stdout)
        exported = export_spec(yaml.safe_load(path.read_text(encoding="utf-8")))
        for table in upstream["tables"]:
            for definition in table.get("definitions") or []:
                key = f"{table['name']}::{definition['name']}"
                record = exported[table["name"]].definitions[definition["name"]]
                assert record.kind == definition["kind"], key
                assert record.type == definition.get("type"), key
                assert record.columns == (definition.get("columns") or []), key
                assert record.definitions == (definition.get("definitions") or []), key


@needs_binary
def test_the_invalid_corpus_also_fails_the_installed_data_dict():
    """Each invalid fixture fails upstream for the reason it was written for.

    The local exporter reports its own messages rather than data-dict's
    problem codes, so the code is asserted against the binary. Without this,
    a fixture could fail locally for an unrelated reason and still look
    honest.
    """
    fixture = load_shared_fixture("definitions")["invalid"]
    for path in _corpus("invalid"):
        result = _run("validate-spec", str(path), "--json")
        assert result.returncode != 0, path.name
        codes = [problem["code"] for problem in json.loads(result.stdout)["problems"]]
        assert fixture[path.name] in codes, path.name


# --- patterns Rust accepts but Python cannot run ---------------------------


def test_a_unicode_class_pattern_is_accepted():
    """data-dict accepts `\\p{L}`; Python's `re` cannot compile it.

    Verified against the binary: it exports as a filter and emits
    `regexp_full_match("region", '\\p{L}+')`. Validity is data-dict's
    question, so commons must not answer it with Python's engine.
    """
    assert one(r"region similar to '\p{L}+'").kind == "filter"


def test_a_rust_named_group_selects_columns():
    # Rust spells a named group `(?<name>...)`, Python `(?P<name>...)`.
    record = export_spec(
        spec(
            {"name": "d", "expr": "columns('(?<prefix>^flag)_') = true"},
            columns=[
                {"name": "flag_a", "type": "boolean"},
                {"name": "other", "type": "boolean"},
            ],
        )
    )["orders"].definitions["d"]
    assert record.columns == ["flag_a"]


def test_a_selector_pattern_python_cannot_run_says_so():
    """A COLUMNS selector has to be matched here, so the engine gap surfaces.

    This is a genuine limitation rather than a rejection of the pattern, so
    the message names the engine instead of calling the pattern invalid.
    """
    with pytest.raises(ValueError, match="cannot evaluate"):
        export_spec(
            spec(
                {"name": "d", "expr": r"columns('\p{L}_') = true"},
                columns=[{"name": "flag_a", "type": "boolean"}],
            )
        )

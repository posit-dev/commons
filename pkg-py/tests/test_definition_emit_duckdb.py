"""Lowering a type-checked expression to DuckDB SQL.

`tests/shared/definitions.json` pins `translation.code` byte for byte and
`notes` exactly, so this is where conformance with data-dict becomes
complete. The unit tests below cover the parts a 42-definition corpus does
not reach, in particular number formatting, where the failure mode is passing
every corpus case and breaking on the next value.
"""

import json
import shutil
import subprocess

import pytest
import yaml

from commons._definitions._export import export_spec
from tests._shared import SHARED_DIR, load_shared_fixture

DATA_DICT = shutil.which("data-dict")


def spec(*definitions: dict, columns: list[dict] | None = None) -> dict:
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


def sql(expr: str, **columns) -> str:
    record = export_spec(spec({"name": "d", "expr": expr}, **columns))[
        "orders"
    ].definitions["d"]
    return record.translations[0]["code"]


def notes(expr: str) -> list[str]:
    record = export_spec(spec({"name": "d", "expr": expr}))["orders"].definitions["d"]
    return record.translations[0]["notes"]


# --- the record's translation ---------------------------------------------


def test_the_translation_names_the_duckdb_target():
    record = export_spec(spec({"name": "d", "expr": "amount > 0"}))[
        "orders"
    ].definitions["d"]
    assert record.translations[0]["target"] == "SQL(duckdb)"
    assert record.translations[0]["error"] is None


# --- identifiers, literals, and quoting ------------------------------------


def test_a_column_is_quoted():
    assert sql("amount > 0") == '"amount" > 0'


def test_a_quote_inside_an_identifier_is_doubled():
    assert (
        sql('`we"ird` > 0', columns=[{"name": 'we"ird', "type": "number"}])
        == '"we""ird" > 0'
    )


def test_a_dotted_path_quotes_each_segment():
    assert (
        sql(
            "payload.total > 0",
            columns=[
                {
                    "name": "payload",
                    "type": "struct",
                    "fields": [{"name": "total", "type": "number"}],
                }
            ],
        )
        == '"payload"."total" > 0'
    )


def test_a_quote_inside_a_string_is_doubled():
    assert sql("region = 'it''s'") == "\"region\" = 'it''s'"


def test_booleans_and_null_are_written_in_caps():
    assert sql("paid = true") == '"paid" = TRUE'
    assert sql("paid = false") == '"paid" = FALSE'
    assert sql("region is null") == '"region" IS NULL'
    assert sql("region is not null") == '"region" IS NOT NULL'


def test_a_date_literal_is_cast():
    assert sql("created >= '2020-01-01'") == "\"created\" >= DATE '2020-01-01'"


def test_a_datetime_literal_is_cast():
    assert (
        sql("shipped >= '2020-01-01T00:00:00Z'")
        == "\"shipped\" >= TIMESTAMP '2020-01-01 00:00:00'"
    )


def test_now_becomes_current_timestamp():
    assert sql("shipped >= now()") == '"shipped" >= current_timestamp'


# --- numbers ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("literal", "expected"),
    [
        ("1", "1"),
        ("007", "7"),
        ("1.5", "1.5"),
        ("0.1", "0.1"),
        ("2.0", "2.0"),
        ("0.12345678901234566", "0.12345678901234566"),
    ],
)
def test_number_literals_are_written_exactly(literal: str, expected: str):
    assert sql(f"amount > {literal}") == f'"amount" > {expected}'


def test_a_float_is_written_in_fixed_notation_however_large():
    # Python's repr would give `1e+20`, which is not what data-dict emits.
    emitted = sql("amount > 100000000000000000000.0")
    written = emitted.split(" > ")[1]
    assert "e" not in written and "E" not in written
    assert float(written) == 1e20


def test_a_float_round_trips_to_the_value_it_came_from():
    for literal in ["0.1", "1.5", "3.14159265358979", "0.000001"]:
        written = sql(f"amount > {literal}").split(" > ")[1]
        assert float(written) == float(literal), literal


def test_a_written_float_always_looks_like_a_float():
    assert sql("amount > 2.0").endswith("2.0")


def test_non_finite_numbers_are_cast():
    assert sql("amount > inf") == "\"amount\" > CAST('Infinity' AS DOUBLE)"
    assert sql("amount > -inf") == "\"amount\" > -CAST('Infinity' AS DOUBLE)"
    assert sql("amount > nan") == "\"amount\" > CAST('NaN' AS DOUBLE)"


# --- precedence ------------------------------------------------------------


def test_a_tighter_child_needs_no_parentheses():
    assert sql("amount > 0 and paid") == '"amount" > 0 AND "paid"'


def test_a_looser_child_is_parenthesised():
    assert (
        sql("(amount > 0 or paid) and region = 'x'")
        == '("amount" > 0 OR "paid") AND "region" = \'x\''
    )


def test_a_right_hand_operand_of_equal_precedence_is_parenthesised():
    assert sql("amount - (amount - amount) > 0") == (
        '"amount" - ("amount" - "amount") > 0'
    )


def test_a_left_hand_operand_of_equal_precedence_is_not():
    assert sql("amount - amount - amount > 0") == ('"amount" - "amount" - "amount" > 0')


def test_multiplication_inside_addition_needs_no_parentheses():
    assert sql("amount + amount * amount > 0") == ('"amount" + "amount" * "amount" > 0')


def test_not_parenthesises_a_looser_operand():
    assert sql("not (amount > 0 and paid)") == 'NOT ("amount" > 0 AND "paid")'


# --- predicates ------------------------------------------------------------


def test_between_and_its_negation():
    assert sql("amount between 1 and 10") == '"amount" BETWEEN 1 AND 10'
    assert sql("amount not between 1 and 10") == '"amount" NOT BETWEEN 1 AND 10'


def test_in_and_its_negation():
    assert sql("region in ('a', 'b')") == "\"region\" IN ('a', 'b')"
    assert sql("region not in ('a')") == "\"region\" NOT IN ('a')"


def test_inequality_is_written_with_one_spelling():
    assert sql("amount != 1") == '"amount" <> 1'
    assert sql("amount <> 1") == '"amount" <> 1'


def test_similar_to_becomes_a_full_match():
    assert sql("region similar to '^x'") == "regexp_full_match(\"region\", '^x')"


def test_case_writes_each_branch():
    assert sql("case when paid then 1 else 0 end") == (
        'CASE WHEN "paid" THEN 1 ELSE 0 END'
    )


def test_case_without_an_else_omits_it():
    assert sql("case when paid then 1 end") == 'CASE WHEN "paid" THEN 1 END'


# --- LIKE lowering ---------------------------------------------------------


def test_a_like_without_wildcards_becomes_equality():
    assert sql("region like 'x'") == "\"region\" = 'x'"
    assert sql("region not like 'x'") == "\"region\" <> 'x'"


def test_a_trailing_wildcard_becomes_starts_with():
    assert sql("region like 'x%'") == "starts_with(\"region\", 'x')"
    assert sql("region not like 'x%'") == "NOT starts_with(\"region\", 'x')"


def test_a_leading_wildcard_becomes_ends_with():
    assert sql("region like '%x'") == "ends_with(\"region\", 'x')"


def test_any_other_wildcard_shape_becomes_a_regex():
    assert sql("region like '%x%'") == "regexp_full_match(\"region\", '^.*x.*$')"


def test_a_single_character_wildcard_becomes_a_dot():
    assert sql("region like 'a_b'") == "regexp_full_match(\"region\", '^a.b$')"


def test_regex_metacharacters_in_a_like_pattern_are_escaped():
    assert sql("region like 'a.b%c'") == ("regexp_full_match(\"region\", '^a\\.b.*c$')")


def test_a_non_literal_like_pattern_stays_a_like():
    assert sql("region like region") == '"region" LIKE "region"'


# --- intervals -------------------------------------------------------------


def test_an_integer_interval_is_written_as_a_literal():
    assert sql("shipped > now() - interval(7, days)") == (
        "\"shipped\" > current_timestamp - INTERVAL '7 days'"
    )


def test_a_computed_interval_is_multiplied_out():
    assert sql("shipped > now() - interval(amount, days)") == (
        '"shipped" > current_timestamp - ("amount" * INTERVAL \'1 days\')'
    )


# --- functions -------------------------------------------------------------


@pytest.mark.parametrize(
    ("expr", "expected"),
    [
        ("lower(region)", 'lower("region")'),
        ("upper(region)", 'upper("region")'),
        ("trim(region)", 'trim("region")'),
        ("length(region)", 'length("region")'),
        ("abs(amount)", 'abs("amount")'),
        ("is_finite(amount)", 'isfinite("amount")'),
        ("is_infinite(amount)", 'isinf("amount")'),
        ("is_nan(amount)", 'isnan("amount")'),
        ("any(paid)", 'bool_or("paid")'),
        ("all(paid)", 'bool_and("paid")'),
        ("row_count()", "count(*)"),
        ("count_distinct(region)", 'count(DISTINCT "region")'),
    ],
)
def test_functions_map_to_their_duckdb_spelling(expr: str, expected: str):
    assert sql(f"{expr} = {expr}").startswith(expected)


def test_mod_is_rewritten_to_keep_the_sign_of_the_divisor():
    assert sql("mod(amount, amount) > 0") == (
        '"amount" > 0'.replace(
            '"amount"',
            'mod(mod("amount", "amount") + "amount", "amount")',
            1,
        )
    )


# --- notes -----------------------------------------------------------------


def test_a_numeric_comparison_carries_the_nan_note():
    assert any("NaN" in note for note in notes("amount > 0"))


def test_a_string_comparison_carries_no_note():
    assert notes("region = 'x'") == []


def test_sum_carries_the_overflow_note():
    assert any("128 bits" in note for note in notes("sum(amount)"))


def test_mod_carries_the_modulus_note():
    assert any("modulus by zero" in note for note in notes("mod(amount, 2) > 0"))


def test_notes_are_sorted_and_deduplicated():
    emitted = notes("amount > 0 and amount < 10")
    assert emitted == sorted(set(emitted))


# --- COLUMNS selections ----------------------------------------------------


def test_a_selection_repeats_the_expression_for_each_column():
    assert (
        sql(
            "columns([a, b]) = true",
            columns=[
                {"name": "a", "type": "boolean"},
                {"name": "b", "type": "boolean"},
            ],
        )
        == '"a" = TRUE AND "b" = TRUE'
    )


# --- conformance -----------------------------------------------------------


def _corpus() -> list:
    return sorted((SHARED_DIR / "definition-export" / "valid").glob("*.yaml"))


def test_the_translation_matches_the_shared_contract():
    fixture = load_shared_fixture("definitions")["export_records"]
    paths = _corpus()
    assert paths, "the shared corpus is empty"
    checked = 0
    for path in paths:
        exported = export_spec(yaml.safe_load(path.read_text(encoding="utf-8")))
        for key, case in fixture[path.name].items():
            table, name = key.split("::")
            translation = exported[table].definitions[name].translations[0]
            assert translation["target"] == case["translation"]["target"], key
            assert translation["code"] == case["translation"]["code"], key
            assert translation["notes"] == case["translation"]["notes"], key
            checked += 1
    assert checked == 42


@pytest.mark.skipif(DATA_DICT is None, reason="the data-dict CLI is not installed")
def test_the_translation_agrees_with_an_installed_data_dict():
    for path in _corpus():
        result = subprocess.run(
            [str(DATA_DICT), "export-spec", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        exported = export_spec(yaml.safe_load(path.read_text(encoding="utf-8")))
        for table in json.loads(result.stdout)["tables"]:
            for definition in table.get("definitions") or []:
                upstream = next(
                    item
                    for item in definition["translations"]
                    if item["target"] == "SQL(duckdb)"
                )
                mine = (
                    exported[table["name"]].definitions[definition["name"]]
                ).translations[0]
                key = f"{table['name']}::{definition['name']}"
                assert mine["code"] == upstream["code"], key
                assert mine["notes"] == (upstream.get("notes") or []), key

"""The definition expression parser: text in, AST out.

These tests pin the AST shape, not just the fact that a parse succeeded. A
parser that accepts everything and builds the wrong tree passes a
"parses the corpus" check, and the type checker downstream would then be
verified against the wrong input.
"""

import pytest

from commons._definitions._expression import Node, parse_expression


def test_a_bare_word_parses_as_a_single_segment_column():
    node = parse_expression("revenue")
    assert node.kind == "column"
    assert node.attrs["path"] == ["revenue"]


def test_a_dotted_word_parses_as_a_field_path():
    path = parse_expression("payload.user.id").attrs["path"]
    assert path == ["payload", "user", "id"]


def test_a_backquoted_name_keeps_its_spaces():
    assert parse_expression("`order total`").attrs["path"] == ["order total"]


def test_a_doubled_backquote_is_one_literal_backquote():
    assert parse_expression("`a``b`").attrs["path"] == ["a`b"]


def test_a_doubled_quote_is_one_literal_quote_in_a_string():
    node = parse_expression("'it''s'")
    assert node.kind == "string"
    assert node.attrs["value"] == "it's"


def test_an_integer_literal_keeps_its_kind():
    node = parse_expression("42")
    assert node.kind == "number"
    assert node.attrs["number_kind"] == "integer"
    assert node.attrs["value"] == 42


def test_a_float_literal_keeps_its_kind():
    node = parse_expression("1.5")
    assert node.attrs["number_kind"] == "float"
    assert node.attrs["value"] == 1.5


def test_leading_zeros_are_stripped_from_an_integer():
    assert parse_expression("007").attrs["value"] == 7


def test_a_trailing_dot_is_not_part_of_the_number():
    # `1.` is a column field-path error, not the float 1.0: the dot only
    # starts a fraction when a digit follows it.
    with pytest.raises(ValueError):
        parse_expression("1.")


def test_an_integer_above_the_64_bit_range_is_refused():
    with pytest.raises(ValueError, match="64-bit integer"):
        parse_expression("9223372036854775808")


def test_the_largest_64_bit_integer_is_accepted():
    assert parse_expression("9223372036854775807").attrs["value"] == (2**63) - 1


def test_booleans_and_null_are_case_insensitive():
    assert parse_expression("TRUE").attrs["value"] is True
    assert parse_expression("False").attrs["value"] is False
    assert parse_expression("null").kind == "null"


def test_addition_is_left_associative():
    node = parse_expression("a + b + c")
    assert node.kind == "arithmetic"
    assert node.attrs["op"] == "+"
    assert node.attrs["lhs"].kind == "arithmetic"
    assert node.attrs["rhs"].attrs["path"] == ["c"]


def test_multiplication_binds_tighter_than_addition():
    node = parse_expression("a + b * c")
    assert node.attrs["op"] == "+"
    assert node.attrs["rhs"].attrs["op"] == "*"


def test_parentheses_override_precedence():
    node = parse_expression("(a + b) * c")
    assert node.attrs["op"] == "*"
    assert node.attrs["lhs"].attrs["op"] == "+"


def test_or_binds_looser_than_and():
    node = parse_expression("a and b or c")
    assert node.kind == "or"
    assert node.attrs["lhs"].kind == "and"


def test_not_applies_to_the_predicate_that_follows_it():
    node = parse_expression("not a = 1")
    assert node.kind == "not"
    assert node.attrs["operand"].kind == "compare"


def test_unary_minus_negates_its_operand():
    node = parse_expression("-a")
    assert node.kind == "negate"
    assert node.attrs["operand"].attrs["path"] == ["a"]


@pytest.mark.parametrize("op", [">=", "<=", "<>", "!=", "=", ">", "<"])
def test_every_comparison_operator_parses(op: str):
    node = parse_expression(f"a {op} 1")
    assert node.kind == "compare"
    assert node.attrs["op"] == op


def test_a_longer_comparison_operator_wins_over_its_prefix():
    assert parse_expression("a >= 1").attrs["op"] == ">="


def test_an_empty_expression_is_refused():
    with pytest.raises(ValueError):
        parse_expression("   ")


def test_trailing_text_after_a_complete_expression_is_refused():
    with pytest.raises(ValueError, match="unexpected text"):
        parse_expression("a = 1 b")


def test_a_node_carries_the_span_it_was_parsed_from():
    node = parse_expression("  revenue")
    assert isinstance(node, Node)
    # 1-based, matching data-dict's "at character N" convention.
    assert (node.start, node.end) == (3, 9)


def test_is_null_parses_without_negation():
    node = parse_expression("a is null")
    assert node.kind == "is_null"
    assert node.attrs["negated"] is False


def test_is_not_null_parses_as_a_negated_is_null():
    assert parse_expression("a is not null").attrs["negated"] is True


def test_between_carries_both_bounds():
    node = parse_expression("a between 1 and 10")
    assert node.kind == "between"
    assert node.attrs["lo"].attrs["value"] == 1
    assert node.attrs["hi"].attrs["value"] == 10
    assert node.attrs["negated"] is False


def test_the_and_in_between_does_not_start_a_conjunction():
    # `1 and 10` must be the bounds, not `a between 1` conjoined with `10`.
    assert parse_expression("a between 1 and 10").kind == "between"


def test_not_between_is_negated():
    assert parse_expression("a not between 1 and 10").attrs["negated"] is True


def test_in_collects_every_item():
    node = parse_expression("a in ('x', 'y', 'z')")
    assert node.kind == "in"
    assert [item.attrs["value"] for item in node.attrs["items"]] == ["x", "y", "z"]


def test_not_in_is_negated():
    assert parse_expression("a not in ('x')").attrs["negated"] is True


def test_like_carries_its_pattern():
    node = parse_expression("a like 'x%'")
    assert node.kind == "like"
    assert node.attrs["pattern"].attrs["value"] == "x%"


def test_similar_to_carries_its_pattern():
    node = parse_expression("a similar to '^x'")
    assert node.kind == "similar"
    assert node.attrs["pattern"].attrs["value"] == "^x"


def test_not_without_a_predicate_keyword_is_refused():
    with pytest.raises(ValueError, match="BETWEEN"):
        parse_expression("a not 'x'")


def test_a_function_call_lowercases_its_name():
    node = parse_expression("SUM(revenue)")
    assert node.kind == "function"
    assert node.attrs["name"] == "sum"
    assert len(node.attrs["args"]) == 1


def test_a_function_call_can_take_no_arguments():
    assert parse_expression("count()").attrs["args"] == []


def test_a_function_call_takes_several_arguments():
    node = parse_expression("coalesce(a, b, 0)")
    assert len(node.attrs["args"]) == 3


def test_whitespace_before_the_parenthesis_still_makes_a_call():
    assert parse_expression("sum (a)").kind == "function"


def test_a_word_not_followed_by_a_parenthesis_is_a_column():
    node = parse_expression("sum + 1")
    assert node.attrs["lhs"].kind == "column"


def test_now_takes_an_empty_argument_list():
    assert parse_expression("now()").kind == "now"


def test_interval_carries_its_count_and_unit():
    node = parse_expression("interval(7, days)")
    assert node.kind == "interval"
    assert node.attrs["n"].attrs["value"] == 7
    assert node.attrs["unit"] == "days"


def test_an_interval_unit_is_lowercased():
    assert parse_expression("interval(1, DAY)").attrs["unit"] == "day"


def test_columns_star_selects_everything():
    assert parse_expression("columns(*)").attrs["selector"] == {"kind": "all"}


def test_columns_with_a_string_is_a_regex_selector():
    selector = parse_expression("columns('^amount_')").attrs["selector"]
    assert selector == {"kind": "regex", "pattern": "^amount_"}


def test_columns_with_a_bracket_list_names_each_column():
    selector = parse_expression("columns([a, `b c`])").attrs["selector"]
    assert selector == {"kind": "list", "names": ["a", "b c"]}


def test_columns_needs_a_recognised_selector():
    with pytest.raises(ValueError, match="regex string"):
        parse_expression("columns(1)")


def test_case_collects_each_when_and_the_else():
    node = parse_expression("case when a then 1 when b then 2 else 3 end")
    assert node.kind == "case"
    assert len(node.attrs["whens"]) == 2
    assert node.attrs["otherwise"].attrs["value"] == 3


def test_case_without_an_else_has_no_otherwise():
    node = parse_expression("case when a then 1 end")
    assert node.attrs["otherwise"] is None


def test_case_needs_at_least_one_when():
    with pytest.raises(ValueError, match="at least one"):
        parse_expression("case end")


def test_case_must_be_closed_with_end():
    with pytest.raises(ValueError, match="END"):
        parse_expression("case when a then 1")


def _corpus_expressions(kind: str) -> list[tuple[str, str, str]]:
    """Every authored expression in a shared corpus directory."""
    import yaml

    from tests._shared import SHARED_DIR

    out: list[tuple[str, str, str]] = []
    for path in sorted((SHARED_DIR / "definition-export" / kind).glob("*.yaml")):
        spec = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for table in spec.get("tables") or []:
            for definition in table.get("definitions") or []:
                out.append((path.name, definition["name"], definition.get("expr")))
    return out


def test_every_valid_corpus_expression_parses():
    cases = _corpus_expressions("valid")
    # An empty corpus would otherwise pass this test silently.
    assert len(cases) == 42
    for filename, name, expr in cases:
        try:
            parse_expression(expr)
        except ValueError as error:  # pragma: no cover - only on a real failure
            pytest.fail(f"{filename}::{name}: {expr!r} did not parse: {error}")


def test_the_unparseable_corpus_fixture_is_refused():
    cases = [case for case in _corpus_expressions("invalid") if case[0] == "parse.yaml"]
    assert cases
    for _, _, expr in cases:
        with pytest.raises(ValueError):
            parse_expression(expr)

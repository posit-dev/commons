"""The definition expression parser: data-dict's expression language to an AST.

Recursive descent over a character cursor, in the same shape as the R parser
in `pkg-r/R/definition-expression.R`, so the two can be read against each
other and against data-dict itself.

Positions are 1-based because they are reported to the author as
"at character N", which is data-dict's convention.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, NoReturn

__all__ = ["Node", "parse_expression"]

RESERVED_WORDS = frozenset(
    {
        "and",
        "or",
        "not",
        "is",
        "null",
        "between",
        "in",
        "like",
        "similar",
        "to",
        "when",
        "then",
        "else",
        "end",
        "true",
        "false",
        "inf",
        "nan",
        "case",
        "columns",
        "now",
        "interval",
    }
)

_WHITESPACE = frozenset(" \t\n\r\f\v")
_COMPARISONS = (">=", "<=", "<>", "!=", "=", ">", "<")
_INT64_MAX = "9223372036854775807"


@dataclass(frozen=True)
class Node:
    """One AST node.

    The per-kind payload lives in `attrs` rather than in subclasses. The type
    checker dispatches on `kind` exactly as the R and Rust implementations do,
    and a flat payload keeps that dispatch readable against them.
    """

    kind: str
    start: int
    end: int
    attrs: dict[str, Any] = field(default_factory=dict)


def parse_expression(text: Any) -> Node:
    """Parse a definition expression, or raise `ValueError` saying where."""
    if not isinstance(text, str) or not text.strip():
        raise ValueError("A definition expression must be a non-empty string.")
    parser = _Parser(text)
    node = _parse_or(parser)
    parser.skip_ws()
    if not parser.eof():
        parser.fail("unexpected text after the expression")
    return node


class _Parser:
    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 1

    def eof(self) -> bool:
        return self.pos > len(self.text)

    def peek(self, offset: int = 0) -> str | None:
        pos = self.pos + offset
        if pos < 1 or pos > len(self.text):
            return None
        return self.text[pos - 1]

    def slice(self, start: int, end: int) -> str:
        return self.text[start - 1 : end]

    def skip_ws(self) -> None:
        while not self.eof() and self.text[self.pos - 1] in _WHITESPACE:
            self.pos += 1

    def try_char(self, char: str, skip_ws: bool = False) -> bool:
        if skip_ws:
            self.skip_ws()
        if self.peek() != char:
            return False
        self.pos += 1
        return True

    def expect(self, char: str) -> None:
        if not self.try_char(char):
            self.fail(f"expected `{char}`")

    def read_word(self) -> str:
        start = self.pos
        while not self.eof() and _identifier_part(self.peek()):
            self.pos += 1
        return self.slice(start, self.pos - 1)

    def match_word(self, word: str) -> bool:
        """Consume `word` when it stands alone, case-insensitively.

        The saved position is restored on any failure, including a word that
        only shares a prefix, so `interval_days` is not read as `interval`.
        """
        save = self.pos
        self.skip_ws()
        end = self.pos + len(word) - 1
        if end > len(self.text):
            self.pos = save
            return False
        candidate = self.slice(self.pos, end)
        after = self.text[end] if end < len(self.text) else None
        if candidate.lower() != word or _identifier_part(after):
            self.pos = save
            return False
        self.pos = end + 1
        return True

    def expect_word(self, word: str) -> None:
        if not self.match_word(word):
            self.fail(f"expected `{word.upper()}`")

    def comparison(self) -> str | None:
        for op in _COMPARISONS:
            end = self.pos + len(op) - 1
            if end <= len(self.text) and self.slice(self.pos, end) == op:
                self.pos = end + 1
                return op
        return None

    def fail(self, message: str, at: int | None = None) -> NoReturn:
        where = self.pos if at is None else at
        raise ValueError(
            f"Invalid definition expression at character {where}. {message}"
        )


def _identifier_start(char: str | None) -> bool:
    return char is not None and (char.isascii() and (char.isalpha() or char == "_"))


def _identifier_part(char: str | None) -> bool:
    return char is not None and (char.isascii() and (char.isalnum() or char == "_"))


def _node(kind: str, start: int, end: int, **attrs: Any) -> Node:
    return Node(kind=kind, start=start, end=end, attrs=attrs)


def _parse_or(parser: _Parser) -> Node:
    lhs = _parse_and(parser)
    while parser.match_word("or"):
        rhs = _parse_and(parser)
        lhs = _node("or", lhs.start, rhs.end, lhs=lhs, rhs=rhs)
    return lhs


def _parse_and(parser: _Parser) -> Node:
    lhs = _parse_not(parser)
    while parser.match_word("and"):
        rhs = _parse_not(parser)
        lhs = _node("and", lhs.start, rhs.end, lhs=lhs, rhs=rhs)
    return lhs


def _parse_not(parser: _Parser) -> Node:
    parser.skip_ws()
    start = parser.pos
    if parser.match_word("not"):
        operand = _parse_not(parser)
        return _node("not", start, operand.end, operand=operand)
    return _parse_predicate(parser)


def _parse_predicate(parser: _Parser) -> Node:
    operand = _parse_additive(parser)
    parser.skip_ws()
    op = parser.comparison()
    if op is not None:
        rhs = _parse_additive(parser)
        return _node("compare", operand.start, rhs.end, op=op, lhs=operand, rhs=rhs)
    if parser.match_word("is"):
        negated = parser.match_word("not")
        parser.expect_word("null")
        return _node(
            "is_null", operand.start, parser.pos - 1, operand=operand, negated=negated
        )
    negated = parser.match_word("not")
    if parser.match_word("between"):
        # The bounds are parsed at additive precedence, so the `AND` that
        # separates them cannot be read as a conjunction.
        lo = _parse_additive(parser)
        parser.expect_word("and")
        hi = _parse_additive(parser)
        return _node(
            "between",
            operand.start,
            hi.end,
            operand=operand,
            lo=lo,
            hi=hi,
            negated=negated,
        )
    if parser.match_word("in"):
        parser.skip_ws()
        parser.expect("(")
        items = [_parse_or(parser)]
        while parser.try_char(",", skip_ws=True):
            items.append(_parse_or(parser))
        parser.skip_ws()
        parser.expect(")")
        return _node(
            "in",
            operand.start,
            parser.pos - 1,
            operand=operand,
            items=items,
            negated=negated,
        )
    if parser.match_word("like"):
        pattern = _parse_additive(parser)
        return _node(
            "like",
            operand.start,
            pattern.end,
            operand=operand,
            pattern=pattern,
            negated=negated,
        )
    if parser.match_word("similar"):
        parser.expect_word("to")
        pattern = _parse_additive(parser)
        return _node(
            "similar",
            operand.start,
            pattern.end,
            operand=operand,
            pattern=pattern,
            negated=negated,
        )
    if negated:
        parser.fail("expected `BETWEEN`, `IN`, `LIKE`, or `SIMILAR TO` after `NOT`")
    return operand


def _parse_additive(parser: _Parser) -> Node:
    lhs = _parse_multiplicative(parser)
    while True:
        parser.skip_ws()
        op = parser.peek()
        if op not in ("+", "-"):
            return lhs
        parser.pos += 1
        rhs = _parse_multiplicative(parser)
        lhs = _node("arithmetic", lhs.start, rhs.end, op=op, lhs=lhs, rhs=rhs)


def _parse_multiplicative(parser: _Parser) -> Node:
    lhs = _parse_unary(parser)
    while True:
        parser.skip_ws()
        op = parser.peek()
        if op not in ("*", "/"):
            return lhs
        parser.pos += 1
        rhs = _parse_unary(parser)
        lhs = _node("arithmetic", lhs.start, rhs.end, op=op, lhs=lhs, rhs=rhs)


def _parse_unary(parser: _Parser) -> Node:
    parser.skip_ws()
    start = parser.pos
    if parser.peek() == "-":
        parser.pos += 1
        operand = _parse_unary(parser)
        return _node("negate", start, operand.end, operand=operand)
    return _parse_primary(parser)


def _parse_primary(parser: _Parser) -> Node:
    parser.skip_ws()
    start = parser.pos
    char = parser.peek()
    if char is None:
        parser.fail("expected an expression")
    if char == "(":
        parser.pos += 1
        inner = _parse_or(parser)
        parser.skip_ws()
        parser.expect(")")
        # The parenthesised span replaces the inner one so error positions
        # point at what the author wrote.
        return Node(inner.kind, start, parser.pos - 1, inner.attrs)
    if char == "'":
        return _parse_string(parser)
    if char == "`":
        name = _parse_quoted_name(parser)
        path = _parse_field_path(parser, name)
        return _node("column", start, parser.pos - 1, path=path)
    if char.isascii() and char.isdigit():
        return _parse_number(parser)
    if _identifier_start(char):
        return _parse_word_primary(parser)
    parser.fail("expected an expression")


def _parse_string(parser: _Parser) -> Node:
    start = parser.pos
    parser.pos += 1
    value: list[str] = []
    while True:
        char = parser.peek()
        if char is None:
            parser.fail("unterminated string literal")
        if char == "'":
            if parser.peek(1) == "'":
                value.append("'")
                parser.pos += 2
                continue
            parser.pos += 1
            break
        value.append(char)
        parser.pos += 1
    return _node("string", start, parser.pos - 1, value="".join(value))


def _parse_number(parser: _Parser) -> Node:
    start = parser.pos
    while (char := parser.peek()) is not None and char.isascii() and char.isdigit():
        parser.pos += 1
    number_kind = "integer"
    following = parser.peek(1)
    if (
        parser.peek() == "."
        and following is not None
        and following.isascii()
        and following.isdigit()
    ):
        number_kind = "float"
        parser.pos += 1
        while (char := parser.peek()) is not None and char.isascii() and char.isdigit():
            parser.pos += 1
    text = parser.slice(start, parser.pos - 1)
    if number_kind == "integer":
        normalized = text.lstrip("0") or "0"
        if len(normalized) > 19 or (len(normalized) == 19 and normalized > _INT64_MAX):
            parser.fail(f"`{text}` is too large for a 64-bit integer", at=start)
        value: Any = int(normalized)
    else:
        value = float(text)
        if value in (float("inf"), float("-inf")):
            parser.fail(f"`{text}` is too large for a number", at=start)
    return _node("number", start, parser.pos - 1, number_kind=number_kind, value=value)


def _parse_word_primary(parser: _Parser) -> Node:
    start = parser.pos
    word = parser.read_word()
    lower = word.lower()
    if lower in ("true", "false"):
        return _node("boolean", start, parser.pos - 1, value=lower == "true")
    if lower == "null":
        return _node("null", start, parser.pos - 1)
    if lower in ("inf", "nan"):
        value = float("inf") if lower == "inf" else float("nan")
        return _node("number", start, parser.pos - 1, number_kind="float", value=value)
    if lower == "case":
        return _parse_case(parser, start)
    if lower == "columns":
        return _parse_columns(parser, start)
    if lower == "now":
        parser.skip_ws()
        parser.expect("(")
        parser.skip_ws()
        parser.expect(")")
        return _node("now", start, parser.pos - 1)
    if lower == "interval":
        return _parse_interval(parser, start)
    if lower in RESERVED_WORDS:
        parser.fail(f"unexpected keyword `{word.upper()}`", at=start)
    # Whitespace may sit between a function name and its arguments, so the
    # cursor rewinds when no call turns up and the word is a column after all.
    after = parser.pos
    parser.skip_ws()
    if parser.peek() == "(":
        parser.pos += 1
        args = _parse_arguments(parser)
        return _node("function", start, parser.pos - 1, name=lower, args=args)
    parser.pos = after
    path = _parse_field_path(parser, word)
    return _node("column", start, parser.pos - 1, path=path)


def _parse_arguments(parser: _Parser) -> list[Node]:
    parser.skip_ws()
    if parser.try_char(")"):
        return []
    args = [_parse_or(parser)]
    while parser.try_char(",", skip_ws=True):
        args.append(_parse_or(parser))
    parser.skip_ws()
    parser.expect(")")
    return args


def _parse_interval(parser: _Parser, start: int) -> Node:
    parser.skip_ws()
    parser.expect("(")
    n = _parse_or(parser)
    parser.skip_ws()
    parser.expect(",")
    parser.skip_ws()
    unit_start = parser.pos
    if not _identifier_start(parser.peek()):
        parser.fail("expected an interval unit")
    unit = parser.read_word()
    parser.skip_ws()
    parser.expect(")")
    return _node(
        "interval",
        start,
        parser.pos - 1,
        n=n,
        unit=unit.lower(),
        unit_start=unit_start,
    )


def _parse_columns(parser: _Parser, start: int) -> Node:
    parser.skip_ws()
    parser.expect("(")
    parser.skip_ws()
    char = parser.peek()
    selector: dict[str, Any]
    if char == "*":
        parser.pos += 1
        selector = {"kind": "all"}
    elif char == "'":
        selector = {"kind": "regex", "pattern": _parse_string(parser).attrs["value"]}
    elif char == "[":
        parser.pos += 1
        names: list[str] = []
        while True:
            parser.skip_ws()
            char = parser.peek()
            if char == "`":
                names.append(_parse_quoted_name(parser))
            elif _identifier_start(char):
                names.append(parser.read_word())
            else:
                parser.fail("expected a column name")
            parser.skip_ws()
            if parser.try_char(","):
                continue
            parser.expect("]")
            break
        selector = {"kind": "list", "names": names}
    else:
        parser.fail("expected `*`, a regex string, or `[names]`")
    parser.skip_ws()
    parser.expect(")")
    return _node("columns", start, parser.pos - 1, selector=selector)


def _parse_case(parser: _Parser, start: int) -> Node:
    whens: list[dict[str, Node]] = []
    while parser.match_word("when"):
        condition = _parse_or(parser)
        parser.expect_word("then")
        result = _parse_or(parser)
        whens.append({"condition": condition, "result": result})
    if not whens:
        parser.fail("`CASE` needs at least one `WHEN ... THEN ...`")
    otherwise = _parse_or(parser) if parser.match_word("else") else None
    parser.expect_word("end")
    return _node("case", start, parser.pos - 1, whens=whens, otherwise=otherwise)


def _parse_quoted_name(parser: _Parser) -> str:
    parser.pos += 1
    value: list[str] = []
    while True:
        char = parser.peek()
        if char is None:
            parser.fail("unterminated quoted name")
        if char == "`":
            if parser.peek(1) == "`":
                value.append("`")
                parser.pos += 2
                continue
            parser.pos += 1
            break
        value.append(char)
        parser.pos += 1
    name = "".join(value)
    if not name:
        parser.fail("a quoted name must not be empty")
    return name


def _parse_field_path(parser: _Parser, first: str) -> list[str]:
    path = [first]
    while parser.peek() == ".":
        parser.pos += 1
        char = parser.peek()
        if char == "`":
            path.append(_parse_quoted_name(parser))
        elif _identifier_start(char):
            path.append(parser.read_word())
        else:
            parser.fail("expected a field name after `.`")
    return path

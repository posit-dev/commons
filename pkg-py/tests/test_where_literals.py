"""The string literal a `where` value becomes, per dialect.

tests/shared/where-literals.json pins it for both packages.
"""

from __future__ import annotations

from typing import Any

import pytest

from commons._pool import _quote_name, _where_condition
from commons._sql_guard import sqlglot_dialect

from ._shared import load_shared_fixture

CASES = load_shared_fixture("where-literals")["cases"]


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["name"])
def test_where_literal(case: dict[str, Any]) -> None:
    triple = {"column": "region", "op": "=", "value": case["value"]}
    for dialect, literal in case["literals"].items():
        name = sqlglot_dialect(dialect)
        condition = _where_condition(triple, ["region"], name)
        assert condition == f"({_quote_name('region', name)} = {literal})", dialect

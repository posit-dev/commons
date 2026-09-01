"""Reject anything that is not a single read-only statement.

The guard parses the statement and checks what it is, rather than matching its
text. A text check is not sound here: a first-word test lets `WITH t AS
(SELECT 1) DELETE FROM sales` through, and every fix for that opens the next
question about what a comment or a quote hides. sqlglot already knows the
grammar, including nested block comments and dollar quoting, so the guard asks
it instead of re-deriving it.

The check is an allowlist. Statements that read are named; everything else is
refused, so a statement form nobody thought of fails closed rather than
falling through a denylist. This pairs with the DuckDB lockdown, and with the
recommendation that a caller-supplied connection be opened read-only, because
commons cannot open someone else's connection for them.
"""

from __future__ import annotations

import sqlglot
from sqlglot import expressions as exp

__all__ = ["check_query"]

# Statement forms that only read. A set operation carries its branches, and
# sqlglot parses a leading CTE list onto the statement it belongs to, so
# `WITH ... DELETE` arrives here as a Delete rather than as a Select.
_READ_ONLY: tuple[type[sqlglot.Expr], ...] = (
    exp.Select,
    exp.Union,
    exp.Intersect,
    exp.Except,
    exp.Subquery,
    exp.Values,
    exp.Pivot,
)

# Nodes that write, wherever they appear in the tree. `DML` and `DDL` cover
# most of them, but sqlglot's hierarchy is not uniform: `Drop` and `Alter`
# descend straight from `Expression`, so they are named here too. None of the
# read-only types above descend from any of these, which a test pins.
_WRITE_NODES: tuple[type[sqlglot.Expr], ...] = (
    exp.DML,
    exp.DDL,
    exp.Drop,
    exp.Alter,
    exp.Attach,
    exp.Detach,
    exp.Install,
    exp.LoadData,
    exp.Grant,
    exp.TruncateTable,
    exp.Set,
    exp.Use,
    exp.Pragma,
    exp.Command,
)

# SQLAlchemy and sqlglot spell some dialects differently.
_DIALECTS = {
    "postgresql": "postgres",
    "mssql": "tsql",
}


def check_query(sql: str, dialect: str | None = None) -> None:
    """Raise `ValueError` unless `sql` is one read-only statement."""
    try:
        parsed = sqlglot.parse(sql, dialect=_sqlglot_dialect(dialect))
    except sqlglot.ParseError as error:
        raise ValueError(
            f"The query could not be parsed as {dialect or 'SQL'}: {error}. "
            "Only read-only SELECT queries are allowed."
        ) from error

    statements = [statement for statement in parsed if statement is not None]
    if not statements:
        raise ValueError("The query is empty. Only read-only SELECT queries are allowed.")
    if len(statements) > 1:
        raise ValueError(
            "The query contains a disallowed semicolon. "
            "Only a single trailing semicolon is allowed."
        )

    statement = statements[0]
    if isinstance(statement, _READ_ONLY):
        # A statement that reads at the root can still carry a write beneath
        # it. PostgreSQL runs data-modifying CTEs, so
        # `WITH d AS (DELETE ... RETURNING *) SELECT * FROM d` is a Select
        # whose CTE deletes rows, and `SELECT ... INTO t` creates a table.
        nested = statement.find(*_WRITE_NODES)
        if nested is not None:
            raise ValueError(
                f"The query contains a disallowed operation: "
                f"{_operation_name(nested)}. "
                "Only read-only SELECT queries are allowed."
            )
        if statement.args.get("into") is not None or statement.find(exp.Into):
            raise ValueError(
                "The query contains a disallowed operation: SELECT INTO. "
                "Only read-only SELECT queries are allowed."
            )
        # A locking read changes no rows but takes locks that block writers,
        # so it is not read-only in the sense the guard promises.
        if statement.args.get("locks") or statement.find(exp.Lock):
            raise ValueError(
                "The query uses a locking read, such as FOR UPDATE. "
                "Only read-only SELECT queries are allowed."
            )
        return

    operation = _operation_name(statement)
    if operation:
        raise ValueError(
            f"The query contains a disallowed operation: {operation}. "
            "Only read-only SELECT queries are allowed."
        )
    raise ValueError(
        "The query must begin with SELECT or WITH. "
        "Only read-only SELECT queries are allowed."
    )


def _sqlglot_dialect(dialect: str | None) -> str | None:
    if dialect is None:
        return None
    name = _DIALECTS.get(dialect.lower(), dialect.lower())
    return name if name in sqlglot.Dialects.__members__.values() else None


def _operation_name(statement: sqlglot.Expr) -> str | None:
    """The keyword to name back to the model, when there is a useful one."""
    if isinstance(statement, exp.Command):
        # sqlglot's fallback for a statement it does not model; the keyword is
        # the payload, e.g. VACUUM.
        this = statement.this
        return str(this).upper() if this else None
    return statement.key.upper()

"""The read-only SQL guard.

The guard parses and classifies rather than matching text. The cases below are
grouped by what they pin: that writes are refused however they are spelled,
that read-only queries a real agent would send still work, and that anything
the parser cannot vouch for fails closed.
"""

import pytest

from commons._sql_guard import check_query

# Writes sqlglot models as a statement type, so the guard can name the
# operation back to the model.
NAMED_WRITES = [
    "DELETE FROM sales",
    "TRUNCATE sales",
    "CREATE TABLE t (x INT)",
    "DROP TABLE sales",
    "ALTER TABLE sales ADD COLUMN x INT",
    "GRANT SELECT ON sales TO bob",
    "REVOKE SELECT ON sales FROM bob",
    "INSERT INTO sales VALUES (1)",
    "UPDATE sales SET x = 1",
    "COPY sales TO '/tmp/out.csv'",
    "ATTACH '/tmp/other.db' AS o",
    "INSTALL httpfs",
    "LOAD httpfs",
    "VACUUM",
]

# Writes and side-effecting statements that the parser refuses outright. They
# are rejected too, just without a keyword to name.
UNPARSEABLE_WRITES = [
    "MERGE INTO sales USING t ON TRUE",
    "REPLACE INTO sales VALUES (1)",
    "UPSERT INTO sales VALUES (1)",
    "EXPORT DATABASE '/tmp/dump'",
]


@pytest.mark.parametrize("sql", NAMED_WRITES)
def test_a_write_is_rejected_and_named(sql: str) -> None:
    with pytest.raises(ValueError, match="disallowed operation"):
        check_query(sql, dialect="duckdb")


@pytest.mark.parametrize("sql", UNPARSEABLE_WRITES)
def test_a_write_the_parser_cannot_model_is_still_rejected(sql: str) -> None:
    with pytest.raises(ValueError):
        check_query(sql, dialect="duckdb")


def test_case_does_not_matter() -> None:
    with pytest.raises(ValueError, match="disallowed operation"):
        check_query("drop table sales", dialect="duckdb")


# DuckDB accepts DML after a CTE list, so `WITH` is not a safe prefix to trust.
# A comment or a quote can hide the paren that ends the CTE, which is why the
# guard parses instead of scanning. Each of these emptied a live table before
# the guard was parser-backed.
@pytest.mark.parametrize(
    "sql",
    [
        "WITH t AS (SELECT 1) DELETE FROM sales",
        "WITH t AS (SELECT 1) INSERT INTO sales VALUES (9)",
        "WITH t AS (SELECT 1) UPDATE sales SET x = 5",
        "WITH RECURSIVE t AS (SELECT 1) DELETE FROM sales",
        "WITH a AS (SELECT 1), b AS (SELECT 2) DELETE FROM sales",
        "WITH t AS (SELECT 1 -- ) SELECT\n) DELETE FROM sales",
        "WITH t AS (SELECT 1 /* ) SELECT */\n) DELETE FROM sales",
        "WITH t AS (SELECT 1 /* ) SELECT /* n */ ) SELECT */ ) DELETE FROM sales",
        "WITH t AS (SELECT $$ ) $$) DELETE FROM sales",
        "WITH t AS (SELECT $tag$ ) $tag$) DELETE FROM sales",
    ],
)
def test_a_write_behind_a_cte_list_is_rejected(sql: str) -> None:
    with pytest.raises(ValueError, match="disallowed operation"):
        check_query(sql, dialect="duckdb")


def test_a_second_statement_is_rejected() -> None:
    with pytest.raises(ValueError, match="disallowed semicolon"):
        check_query("SELECT 1 AS ok; DROP TABLE sales;", dialect="duckdb")


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT 'dropped' AS status FROM sales",
        "WITH total AS (SELECT 1) SELECT * FROM total",
        "SELECT 1;",
        "  select 1  ",
        "SELECT\n  1\nFROM sales",
        "WITH RECURSIVE t AS (SELECT 1) SELECT * FROM t",
        "WITH a AS (SELECT 1), b AS (SELECT 2) SELECT * FROM a JOIN b ON TRUE",
        "(SELECT 1)",
        "SELECT 1 UNION SELECT 2",
        "SELECT 1 INTERSECT SELECT 2",
        "SELECT 1 EXCEPT SELECT 2",
    ],
)
def test_a_read_only_statement_is_accepted(sql: str) -> None:
    check_query(sql, dialect="duckdb")


# A keyword-matching guard would reject these, and they are ordinary SQL.
@pytest.mark.parametrize(
    "sql",
    [
        "SELECT * FROM sales WHERE note = 'DELETE'",
        "SELECT replace(name, 'a', 'b') FROM sales",
        "SELECT 1 -- a trailing note",
        "SELECT 1 /* an inline note */ FROM sales",
        "SELECT 1 /* outer /* inner */ still outer */ AS n",
        "WITH t AS (SELECT 1) -- explain the join\nSELECT * FROM t",
        "SELECT $$ ) not a paren $$ AS n",
        "SELECT $tag$ ) $tag$ AS n FROM sales",
        "SELECT 'it''s ) fine' AS n FROM sales",
    ],
)
def test_a_blocked_word_that_is_not_an_operation_is_accepted(sql: str) -> None:
    check_query(sql, dialect="duckdb")


# Dialect syntax a model would plausibly emit against a DuckDB source.
@pytest.mark.parametrize(
    "sql",
    [
        "SELECT * EXCLUDE (region) FROM sales",
        "SELECT * REPLACE (revenue * 2 AS revenue) FROM sales",
        "SELECT x FROM sales QUALIFY row_number() OVER (PARTITION BY x) = 1",
        "FROM sales SELECT region",
        "SELECT list_transform([1, 2], x -> x * 2) AS n",
        "SELECT a[1:2] FROM sales",
        "SELECT {'a': 1} AS s",
        "SELECT * FROM sales ASOF JOIN t ON sales.x >= t.x",
    ],
)
def test_read_only_dialect_syntax_is_accepted(sql: str) -> None:
    check_query(sql, dialect="duckdb")


def test_sql_the_parser_cannot_read_is_rejected_rather_than_guessed() -> None:
    # Fail closed: a statement the guard cannot classify is one it cannot
    # vouch for.
    with pytest.raises(ValueError, match="could not be parsed"):
        check_query("SELECT FROM WHERE )(", dialect="duckdb")


def test_an_empty_query_is_rejected() -> None:
    with pytest.raises(ValueError):
        check_query("   ", dialect="duckdb")


def test_an_unknown_dialect_falls_back_rather_than_failing() -> None:
    # A backend sqlglot has no dialect for still gets the generic grammar,
    # which is enough to tell a SELECT from a DELETE.
    check_query("SELECT 1", dialect="some-warehouse")
    with pytest.raises(ValueError, match="disallowed operation"):
        check_query("DELETE FROM sales", dialect="some-warehouse")


def test_a_sqlalchemy_dialect_name_maps_to_the_parser_name() -> None:
    check_query("SELECT 1", dialect="postgresql")


# A statement whose root node reads can still carry a write underneath it.
# PostgreSQL runs data-modifying CTEs, and SELECT ... INTO creates a table.
@pytest.mark.parametrize(
    ("dialect", "sql"),
    [
        ("postgres", "WITH d AS (DELETE FROM sales RETURNING *) SELECT * FROM d"),
        ("postgres", "WITH i AS (INSERT INTO sales VALUES (1) RETURNING *) SELECT * FROM i"),
        ("postgres", "WITH u AS (UPDATE sales SET x = 1 RETURNING *) SELECT * FROM u"),
        ("duckdb", "WITH d AS (DELETE FROM sales RETURNING *) SELECT * FROM d"),
        ("postgres", "SELECT * INTO new_table FROM sales"),
        ("tsql", "SELECT * INTO new_table FROM sales"),
        ("postgres", "SELECT * FROM (WITH d AS (DELETE FROM sales RETURNING *) SELECT * FROM d) q"),
    ],
)
def test_a_write_nested_under_a_read_is_rejected(dialect: str, sql: str) -> None:
    with pytest.raises(ValueError, match="disallowed operation"):
        check_query(sql, dialect=dialect)


@pytest.mark.parametrize(
    ("dialect", "sql"),
    [
        ("postgres", "WITH d AS (SELECT * FROM sales) SELECT * FROM d"),
        ("postgres", "SELECT * FROM (SELECT 1 AS x) q"),
        ("duckdb", "SELECT * FROM sales WHERE x IN (SELECT y FROM other)"),
    ],
)
def test_a_read_nested_under_a_read_is_still_accepted(dialect: str, sql: str) -> None:
    check_query(sql, dialect=dialect)


def test_no_read_only_statement_type_is_also_a_write_node() -> None:
    # The nested-write check runs over statements the allowlist already
    # accepted, so an overlap between the two sets would reject every query.
    from commons._sql_guard import _READ_ONLY, _WRITE_NODES

    for allowed in _READ_ONLY:
        assert not issubclass(allowed, _WRITE_NODES), allowed.__name__


# A locking read does not modify rows, but it takes locks that block writers,
# which is not the read-only behaviour the guard promises.
@pytest.mark.parametrize(
    ("dialect", "sql"),
    [
        ("postgres", "SELECT * FROM sales FOR UPDATE"),
        ("postgres", "SELECT * FROM sales FOR SHARE"),
        ("postgres", "SELECT * FROM sales FOR UPDATE NOWAIT"),
        ("postgres", "SELECT * FROM sales FOR NO KEY UPDATE"),
        ("mysql", "SELECT * FROM sales LOCK IN SHARE MODE"),
    ],
)
def test_a_locking_read_is_rejected(dialect: str, sql: str) -> None:
    with pytest.raises(ValueError, match="locking"):
        check_query(sql, dialect=dialect)


def test_a_plain_read_of_the_same_table_is_still_accepted() -> None:
    check_query("SELECT * FROM sales", dialect="postgres")

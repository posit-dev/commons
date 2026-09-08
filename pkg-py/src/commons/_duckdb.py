"""The in-process DuckDB that backs frame and pin data sources.

``lock_down`` is a security control, not a nicety: a data source built from
frames must not be able to reach the host filesystem. ``pkg-r/R/data-source.R``
applies the same settings.
"""

from __future__ import annotations

import tempfile
from pathlib import Path

import duckdb

__all__ = ["connect", "lock_down", "quote_identifier"]

_LOCKDOWN_SQL = """
SET allow_community_extensions = false;
SET allow_unsigned_extensions = false;
SET autoinstall_known_extensions = false;
SET autoload_known_extensions = false;
SET enable_external_access = false;
SET disabled_filesystems = 'LocalFileSystem';
SET lock_configuration = true;
"""


def connect() -> duckdb.DuckDBPyConnection:
    """Open an in-memory DuckDB with its scratch directories under temp.

    DuckDB defaults its extension and home directories to the install location,
    which is read-only in deployed environments such as Posit Connect.
    `extension_directory` has to be set at startup, because the first query
    initializes the extension subsystem against it. `home_directory` is a
    process-global option, so passing it in `config` re-sets a global on every
    connection and DuckDB rejects that once any instance exists in the process;
    set it with a session-scoped SET instead.
    """
    directory = Path(tempfile.gettempdir()) / "duckdb"
    directory.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(config={"extension_directory": str(directory)})
    con.execute("SET home_directory = ?", [str(directory)])
    return con


def lock_down(con: duckdb.DuckDBPyConnection) -> None:
    """Disable extension loading and filesystem access, then freeze the config.

    `lock_configuration` only freezes SET statements, so tables can still be
    written afterwards. The board path relies on that.
    """
    con.execute(_LOCKDOWN_SQL)


def quote_identifier(name: str) -> str:
    """Quote `name` as a DuckDB identifier, doubling any embedded quote.

    Table names come from caller-supplied keyword arguments and go into SQL
    that runs before `lock_down`, so an unescaped one would be an injection
    point the lockdown never gets a chance to close.
    """
    return '"' + name.replace('"', '""') + '"'

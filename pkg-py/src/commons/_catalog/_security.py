"""Session identity and query access for a warehouse catalog.

A warehouse decides what a principal may read, so commons never tries to
answer that itself: it asks, with a query that returns no rows, and reads the
answer off the failure. The classification matters because it decides what
happens next. An authorization refusal is stable, so it is remembered and the
relation is not probed again; a transient one is not, so the next touch
retries; anything unrecognized is neither cached nor treated as a refusal.

The session snapshot exists for the same reason. Access was decided for the
principal, role, and namespace in force at discovery, so if any of those
change the answers no longer apply and the source has to be rebuilt.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, NoReturn

from .._data_source import TableId
from ._core import Manifest, Relation

__all__ = [
    "CatalogAccessError",
    "CatalogAuthorizationError",
    "CatalogSessionChangedError",
    "CatalogTransientError",
    "Probe",
    "SessionSnapshot",
    "changed_session_fields",
    "check_session",
    "classify_access_error",
    "ensure_queryable",
    "probe_relation",
    "probe_sql",
    "require_queryable",
    "require_queryable_relations",
    "session_snapshot",
]

_AUTHORIZATION_MESSAGE = re.compile(
    "not authorized|insufficient privilege|permission denied|"
    "access denied|does not have.*privilege|not permitted|"
    "permission_denied|sql access control error|not allowed to access",
    re.IGNORECASE,
)

_TRANSIENT_MESSAGE = re.compile(
    "temporar|timed? ?out|unavailable|connection.*(closed|reset|failed)|"
    "warehouse.*(starting|stopped|unavailable)|throttl|rate limit|"
    "network|socket|http (429|503)|unexpected eof",
    re.IGNORECASE,
)

_TRANSIENT_SQLSTATE = re.compile("^08|^HYT|^40|^57P01")


class CatalogAccessError(Exception):
    """Query access to a relation could not be verified."""


class CatalogAuthorizationError(CatalogAccessError):
    """The current principal may not query the relation."""


class CatalogTransientError(CatalogAccessError):
    """Access could not be verified now, but might be on a later try."""


class CatalogSessionChangedError(Exception):
    """The connection's identity moved after the catalog was discovered."""


@dataclass(frozen=True)
class SessionSnapshot:
    """The connection identity the catalog's access answers were decided for."""

    backend: str
    principal: str | None
    catalog: str | None
    schema: str | None
    role: str | None = None
    secondary_roles: str | None = None


@dataclass(frozen=True)
class Probe:
    state: str
    error: BaseException | None = None


def session_snapshot(backend: Any) -> SessionSnapshot | None:
    """Read the identity a Snowflake or Databricks connection is acting under.

    Any other backend returns None: nothing else commons supports scopes
    catalog access to a role that can change underneath the source.
    """
    dialect = backend.dialect()
    if dialect == "snowflake":
        sql = (
            "SELECT CURRENT_USER() AS principal, CURRENT_ROLE() AS role, "
            "CURRENT_SECONDARY_ROLES() AS secondary_roles, "
            "CURRENT_DATABASE() AS catalog, CURRENT_SCHEMA() AS schema"
        )
    elif dialect == "databricks":
        sql = (
            "SELECT CURRENT_USER() AS principal, "
            "CURRENT_CATALOG() AS catalog, CURRENT_SCHEMA() AS schema"
        )
    else:
        return None

    try:
        rows = backend.query(sql)
    except Exception as error:
        raise RuntimeError(f"Failed to read the {dialect} session identity.") from error
    return _session_row(rows, dialect)


def _session_row(rows: list[dict[str, Any]], dialect: str) -> SessionSnapshot:
    has_roles = dialect == "snowflake"
    required = ["principal", "catalog", "schema"]
    if has_roles:
        required += ["role", "secondary_roles"]
    row = {str(key).lower(): value for key, value in rows[0].items()} if rows else {}
    if len(rows) != 1 or not all(field in row for field in required):
        raise ValueError(f"{dialect} returned an invalid session identity response.")
    return SessionSnapshot(
        backend=dialect,
        principal=_session_value(row["principal"]),
        catalog=_session_value(row["catalog"]),
        schema=_session_value(row["schema"]),
        role=_session_value(row["role"]) if has_roles else None,
        secondary_roles=(_session_value(row["secondary_roles"]) if has_roles else None),
    )


def _session_value(value: Any) -> str | None:
    if value is None or str(value) == "":
        return None
    return str(value)


def check_session(backend: Any, snapshot: SessionSnapshot | None) -> None:
    """Refuse to go on when the connection is no longer who it was."""
    if snapshot is None:
        return
    current = session_snapshot(backend)
    if current == snapshot:
        return
    changed = [
        _FIELD_NAMES[field] for field in changed_session_fields(current, snapshot)
    ]
    raise CatalogSessionChangedError(
        f"The connection {_listed(changed) or 'identity'} changed after "
        f"catalog discovery; rebuild the data source."
    )


def _listed(items: Any) -> str:
    """A comma-separated list a person would read out loud."""
    items = list(items)
    if len(items) < 2:
        return "".join(items)
    return f"{', '.join(items[:-1])} and {items[-1]}"


# How each snapshot field is worded in the refusal.
_FIELD_NAMES = {
    "principal": "principal",
    "role": "active role",
    "secondary_roles": "secondary roles",
    "catalog": "catalog",
    "schema": "schema",
}


def changed_session_fields(
    current: SessionSnapshot | None, snapshot: SessionSnapshot
) -> list[str]:
    """Which parts of the session identity differ, in snapshot order.

    The refusal names what moved rather than everything it compares, because
    a backend need not have every field: Databricks reports no role, and
    naming one there sends the user looking for something that cannot change.
    """
    if current is None:
        return []
    return [
        field
        for field in _FIELD_NAMES
        if getattr(current, field) != getattr(snapshot, field)
    ]


def probe_sql(backend: Any, sql: str) -> Probe:
    try:
        backend.query(sql)
    except Exception as error:  # noqa: BLE001 - the failure is the answer
        return Probe(classify_access_error(error), error)
    return Probe("queryable")


def probe_relation(backend: Any, table_id: TableId) -> Probe:
    return probe_sql(backend, f"SELECT * FROM {backend.quote(table_id)} WHERE 1 = 0")


def classify_access_error(error: BaseException) -> str:
    """Read a driver's failure as authorization, transient, or neither.

    Conservative in both directions: a refusal is only called authorization
    when the driver said so, and everything unrecognized stays unknown so it
    is neither cached nor retried on its own.
    """
    sqlstate = _sqlstate(error)
    message = str(error)
    if (
        sqlstate.startswith("28")
        or sqlstate == "42501"
        or _AUTHORIZATION_MESSAGE.search(message)
    ):
        return "authorization"
    if _TRANSIENT_SQLSTATE.match(sqlstate) or _TRANSIENT_MESSAGE.search(message):
        return "transient"
    return "unknown"


def _sqlstate(error: BaseException) -> str:
    """The SQLSTATE a driver reported, wherever it hung it.

    DBAPI drivers put it on the exception, SQLAlchemy wraps that exception in
    one of its own, so the cause is read too.
    """
    for candidate in (error, getattr(error, "orig", None), error.__cause__):
        if candidate is None:
            continue
        for attribute in ("sqlstate", "state"):
            value = getattr(candidate, attribute, None)
            if isinstance(value, str) and value:
                return value.upper()
    return ""


def require_queryable(
    backend: Any, table_id: TableId, label: str | None = None
) -> None:
    probe = probe_relation(backend, table_id)
    if probe.state != "queryable":
        _abort_access(probe, label or table_id.label)


def require_queryable_relations(
    backend: Any,
    validate: dict[str, TableId],
    relations: dict[str, Relation] | None = None,
) -> None:
    """Check every explicitly named relation before the source is built.

    A name the warehouse never reported is missing rather than refused, and
    saying so is more use than an access error about a table that is not
    there. An unexplained failure is only reported as missing when the
    backend can confirm the relation's absence.

    Every relation the listing did report is probed before anything is
    raised. Stopping at the first refusal would report one problem at a time,
    and would report it ahead of a name the caller simply got wrong.
    """
    missing = [
        label
        for label in validate
        if relations is not None and not relations[label].discovered
    ]
    # Only the first refusal is raised, so only the first is kept: a
    # selection may run to thousands of relations.
    refused: tuple[Probe, str] | None = None
    for label, table_id in validate.items():
        if label in missing:
            continue
        probe = probe_relation(backend, table_id)
        if probe.state == "queryable":
            continue
        if probe.state == "unknown" and _relation_exists(backend, table_id) is False:
            missing.append(label)
            continue
        refused = refused or (probe, label)
    if missing:
        _abort_missing(missing)
    if refused is not None:
        _abort_access(*refused)


def _relation_exists(backend: Any, table_id: TableId) -> bool | None:
    inspector = backend.inspector()
    if inspector is None:
        return None
    try:
        return bool(inspector(table_id))
    except Exception:  # noqa: BLE001 - inconclusive; the caller keeps the probe
        return None


def ensure_queryable(
    backend: Any, manifest: Manifest | None, label: str, table_id: TableId
) -> None:
    """Check access to one relation at the moment it is about to be used.

    Construction only probes what the caller named and what the dictionary
    matched, so a relation that arrived through a namespace listing is first
    checked here. Its caller is the first-touch path that describes a table
    to the agent, which lands with the retrieval surface; until then nothing
    in commons resolves a label at query time.
    """
    if manifest is None:
        return
    state = manifest.access.get(label, "unknown")
    if state == "queryable":
        return
    if state == "authorization":
        _abort_access(Probe(state, manifest.access_errors.get(label)), label)

    probe = probe_relation(backend, table_id)
    if probe.state == "queryable":
        manifest.access[label] = "queryable"
        return
    # Only stable authorization failures are cached; other failures retry.
    if probe.state == "authorization":
        manifest.access[label] = probe.state
        if probe.error is not None:
            manifest.access_errors[label] = probe.error
    _abort_access(probe, label)


def _abort_missing(missing: list[str]) -> NoReturn:
    noun = "a table" if len(missing) == 1 else "tables"
    raise ValueError(
        f"tables must not name {noun} the connection does not have: "
        f"{_listed(repr(label) for label in missing)}."
    )


def _abort_access(probe: Probe, label: str) -> NoReturn:
    if probe.state == "authorization":
        raise CatalogAuthorizationError(
            f"The current principal is not authorized to query {label!r}."
        ) from probe.error
    if probe.state == "transient":
        raise CatalogTransientError(
            f"Query access to {label!r} is temporarily unavailable."
        ) from probe.error
    raise CatalogAccessError(
        f"Could not verify query access to {label!r}."
    ) from probe.error

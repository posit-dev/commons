"""Approved descriptive counts for the supplied hospital event dataset."""

from __future__ import annotations

from typing import Annotated, Any, Literal

from pydantic import Field

from commons import Injected, measure


@measure(
    description="Approved recorded-event count and distinct hospital, event-type, and severity counts, optionally filtered by exact hospital name."
)
def hospital_summary(
    hospital: Injected[Any],
    hospital_name: Annotated[
        str | None, Field(description="Exact hospital name; omit for all hospitals.")
    ] = None,
) -> dict[str, Any]:
    row = hospital.execute(
        "SELECT COUNT(*), COUNT(DISTINCT hospitals_table), "
        "COUNT(DISTINCT events_table), COUNT(DISTINCT severity_table) "
        "FROM hospital_events WHERE (? IS NULL OR hospitals_table = ?)",
        [hospital_name, hospital_name],
    ).fetchone()
    return dict(
        zip(("event_count", "hospitals", "event_types", "severity_levels"), row)
    )


@measure(
    description="Approved recorded-event counts grouped by hospital, event type, or severity, optionally filtered by exact hospital name. These are counts, not incidence rates."
)
def hospital_event_counts(
    hospital: Injected[Any],
    group_by: Annotated[
        Literal["hospital", "event_type", "severity"],
        Field(description="Category to group recorded events by."),
    ],
    hospital_name: Annotated[
        str | None, Field(description="Exact hospital name; omit for all hospitals.")
    ] = None,
) -> dict[str, Any]:
    column = {
        "hospital": "hospitals_table",
        "event_type": "events_table",
        "severity": "severity_table",
    }[group_by]
    rows = hospital.execute(
        f"SELECT {column}, COUNT(*) FROM hospital_events "
        f"WHERE (? IS NULL OR hospitals_table = ?) GROUP BY {column} "
        f"ORDER BY COUNT(*) DESC, {column}",
        [hospital_name, hospital_name],
    ).fetchall()
    return {
        "group_by": group_by,
        "rows": [
            {"category": category, "event_count": count} for category, count in rows
        ],
    }

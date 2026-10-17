"""Live MCP coverage for the Connect demo's hospital source."""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import httpx
import pytest

from commons import mcp_server
from commons._mcp import RemoteSession

from ._mcp_server import _serve_demo

TOOLS = (
    "revenue",
    "hospital_summary",
    "hospital_event_counts",
    "run_sql",
    "describe_table",
)
AUTH_HEADERS = {"Authorization": "Key verified-by-proxy"}
HOSPITAL_DICTIONARY = "commons://sources/hospital/data-dict.yaml"


@pytest.fixture(scope="module")
def hospital_server(tmp_path_factory: pytest.TempPathFactory) -> Iterator[str]:
    yield from _serve_demo(tmp_path_factory, proxy=True)


@pytest.fixture(scope="module")
def hospital_session(hospital_server: str) -> Iterator[RemoteSession]:
    session = RemoteSession(
        mcp_server(
            "hospital",
            f"{hospital_server}/mcp/",
            auth={"headers": AUTH_HEADERS},
            tools=TOOLS,
        )
    )
    try:
        yield session
    finally:
        session.close()


def _call(
    session: RemoteSession, name: str, arguments: dict[str, Any]
) -> dict[str, Any]:
    return session.submit(session.call(name, arguments)).result(timeout=10)


def _rejected_call(
    session: RemoteSession, name: str, arguments: dict[str, Any], expected_error: str
) -> None:
    reply = session.submit(
        session.client.call_tool(
            name,
            arguments,
            meta={"commons_catalog_revision": session.revision},
            raise_on_error=False,
        )
    ).result(timeout=10)
    assert reply.is_error
    assert expected_error in "\n".join(
        part.text for part in reply.content if hasattr(part, "text")
    )


def test_connect_catalog_exposes_both_sources_and_all_five_tools(
    hospital_server: str, hospital_session: RemoteSession
) -> None:
    rest = httpx.get(
        f"{hospital_server}/v1/catalog",
        headers=AUTH_HEADERS,
    )
    assert rest.status_code == 200
    assert rest.json() == hospital_session.catalog
    assert {tool["name"] for tool in rest.json()["tools"]} == set(TOOLS)
    assert {
        source["id"]: set(source["tables"]) for source in rest.json()["sources"]
    } == {
        "warehouse": {"orders"},
        "hospital": {"hospital_events"},
    }


def test_approved_hospital_measures_count_rows_and_exact_filters(
    hospital_session: RemoteSession,
) -> None:
    summary = _call(hospital_session, "hospital_summary", {})
    assert summary["data"] == {
        "event_count": 10_000,
        "hospitals": 4,
        "event_types": 10,
        "severity_levels": 3,
    }
    assert summary["commons"]["provenance_tag"] == "A"
    assert summary["commons"]["sources"] == ["hospital"]
    assert {evidence["uri"] for evidence in summary["commons"]["evidence"]} == {
        HOSPITAL_DICTIONARY,
        "commons://measures/hospital_summary",
    }

    filtered = _call(
        hospital_session,
        "hospital_summary",
        {"hospital_name": "Example Women's Hospital"},
    )
    assert filtered["data"] == {
        "event_count": 1000,
        "hospitals": 1,
        "event_types": 10,
        "severity_levels": 3,
    }

    missing = _call(
        hospital_session,
        "hospital_summary",
        {"hospital_name": "No such hospital"},
    )
    assert missing["data"] == {
        "event_count": 0,
        "hospitals": 0,
        "event_types": 0,
        "severity_levels": 0,
    }


def test_hospital_grouped_measure_counts_match_the_dataset(
    hospital_session: RemoteSession,
) -> None:
    hospitals = _call(
        hospital_session,
        "hospital_event_counts",
        {"group_by": "hospital"},
    )
    assert {
        row["category"]: row["event_count"] for row in hospitals["data"]["rows"]
    } == {
        "Example General Hospital": 4000,
        "Example Port Hospital": 3000,
        "Example Military Hospital": 2000,
        "Example Women's Hospital": 1000,
    }

    severity = _call(
        hospital_session,
        "hospital_event_counts",
        {"group_by": "severity"},
    )
    assert {
        row["category"]: row["event_count"] for row in severity["data"]["rows"]
    } == {"Level 1": 6500, "Level 2": 3000, "Level 3": 500}

    event_types = _call(
        hospital_session, "hospital_event_counts", {"group_by": "event_type"}
    )
    assert {
        row["category"]: row["event_count"] for row in event_types["data"]["rows"]
    } == {
        category: 1000
        for category in (
            "diagnostic error",
            "medical complication",
            "behavior problem",
            "admission/discharge issue",
            "environmental hazard",
            "surgical complication",
            "transfusion problem",
            "medication error",
            "equipment problem",
            "perinatal problem",
        )
    }

    hospital_name = "Example Women's Hospital"
    filtered_severity = _call(
        hospital_session,
        "hospital_event_counts",
        {"group_by": "severity", "hospital_name": hospital_name},
    )
    assert {
        row["category"]: row["event_count"] for row in filtered_severity["data"]["rows"]
    } == {"Level 1": 650, "Level 2": 300, "Level 3": 50}

    filtered_hospital = _call(
        hospital_session,
        "hospital_event_counts",
        {"group_by": "hospital", "hospital_name": hospital_name},
    )
    assert filtered_hospital["data"]["rows"] == [
        {"category": hospital_name, "event_count": 1000}
    ]


def test_hospital_sql_and_describe_use_hospital_evidence(
    hospital_session: RemoteSession,
) -> None:
    result = _call(
        hospital_session,
        "run_sql",
        {
            "source": "hospital",
            "sql": (
                "SELECT severity_table, COUNT(*) AS event_count "
                "FROM hospital_events GROUP BY severity_table "
                "ORDER BY severity_table"
            ),
        },
    )
    assert result["data"] == {
        "columns": ["severity_table", "event_count"],
        "rows": [["Level 1", 6500], ["Level 2", 3000], ["Level 3", 500]],
    }
    assert result["commons"]["provenance_tag"] == "B"
    assert result["commons"]["sources"] == ["hospital"]
    assert [item["uri"] for item in result["commons"]["evidence"]] == [
        HOSPITAL_DICTIONARY
    ]

    described = _call(
        hospital_session,
        "describe_table",
        {"source": "hospital", "table": "hospital_events"},
    )
    assert [column[0] for column in described["data"]["schema"]] == [
        "hospitals_table",
        "events_table",
        "severity_table",
    ]
    assert described["commons"]["sources"] == ["hospital"]


def test_warehouse_measure_remains_available_in_the_shared_catalog(
    hospital_session: RemoteSession,
) -> None:
    result = _call(hospital_session, "revenue", {})
    assert result["data"] == {"revenue": 180_000, "currency": "USD"}
    assert result["commons"]["provenance_tag"] == "A"
    assert result["commons"]["sources"] == ["warehouse"]
    assert {evidence["uri"] for evidence in result["commons"]["evidence"]} == {
        "commons://sources/warehouse/data-dict.yaml",
        "commons://measures/revenue",
    }
    assert (
        _call(
            hospital_session,
            "revenue",
            {"region": "North"},
        )["data"]["revenue"]
        == 90_000
    )
    assert (
        _call(
            hospital_session,
            "revenue",
            {"region": "South"},
        )["data"]["revenue"]
        == 90_000
    )
    count = _call(
        hospital_session,
        "run_sql",
        {"source": "warehouse", "sql": "SELECT COUNT(*) FROM orders"},
    )
    assert count["data"]["rows"] == [[480]]


def test_hospital_resources_match_rest_and_mcp(
    hospital_server: str, hospital_session: RemoteSession
) -> None:
    resources = (
        (
            "/v1/data-dictionaries/hospital",
            HOSPITAL_DICTIONARY,
        ),
        ("/v1/contexts/hospital-policy", "commons://contexts/hospital-policy"),
    )
    for route, uri in resources:
        response = httpx.get(
            f"{hospital_server}{route}",
            headers=AUTH_HEADERS,
        )
        assert response.status_code == 200
        mcp_text = hospital_session.submit(hospital_session._resource_text(uri)).result(
            timeout=10
        )
        assert response.text == mcp_text
        assert (
            response.headers["X-Commons-Catalog-Revision"] == hospital_session.revision
        )


@pytest.mark.parametrize(
    ("source", "sql"),
    [
        ("hospital", "SELECT * FROM orders"),
        (
            "hospital",
            "WITH hidden AS (SELECT * FROM orders) SELECT * FROM hidden",
        ),
        ("warehouse", "SELECT * FROM hospital_events"),
        (
            "warehouse",
            "WITH hidden AS (SELECT * FROM hospital_events) SELECT * FROM hidden",
        ),
    ],
)
def test_sql_cannot_read_tables_outside_its_source(
    hospital_session: RemoteSession, source: str, sql: str
) -> None:
    with pytest.raises(ValueError, match="returned an error"):
        _call(hospital_session, "run_sql", {"source": source, "sql": sql})


@pytest.mark.parametrize(
    ("source", "table"),
    [("hospital", "orders"), ("warehouse", "hospital_events")],
)
def test_describe_table_rejects_a_table_from_another_source(
    hospital_session: RemoteSession, source: str, table: str
) -> None:
    _rejected_call(
        hospital_session,
        "describe_table",
        {"source": source, "table": table},
        "does not belong to the requested source",
    )


def test_invalid_group_and_injection_shaped_filter_do_not_change_data(
    hospital_session: RemoteSession,
) -> None:
    _rejected_call(
        hospital_session,
        "hospital_event_counts",
        {"group_by": "hospital); DROP TABLE orders; --"},
        "is not one of",
    )
    injected_filter = _call(
        hospital_session,
        "hospital_summary",
        {"hospital_name": "' OR 1=1 --"},
    )
    assert injected_filter["data"]["event_count"] == 0
    assert (
        _call(hospital_session, "hospital_summary", {})["data"]["event_count"] == 10_000
    )


def test_hospital_sql_results_declare_row_truncation(
    hospital_session: RemoteSession,
) -> None:
    result = _call(
        hospital_session,
        "run_sql",
        {
            "source": "hospital",
            "sql": (
                "SELECT hospitals_table FROM hospital_events ORDER BY hospitals_table"
            ),
        },
    )
    assert len(result["data"]["rows"]) == 100
    assert result["commons"]["coverage"]["truncated"] is True

"""Shared MCP result contract and real HTTP integration tests."""

from __future__ import annotations

import asyncio
import inspect
import json
import time
from collections.abc import Iterable, Iterator, Sequence
from copy import deepcopy
from pathlib import Path
from typing import Any, cast, get_type_hints

import httpx
import pytest
from chatlas import ContentToolRequest, ContentToolResult, Tool

from commons import Commons, MCPServer, mcp_server, semantic_layer
from commons._mcp import _TAGS, RemoteSession, _validator
from commons._provenance import TAG_EXTRA_KEY, Tag, derive_provenance_tag
from commons._reminders import ContentTurnReminder

from ._mcp_server import API_KEY, _serve_demo
from ._provider import ScriptedProvider, scripted_chat, text
from ._shared import load_shared_fixture

CONTRACT = load_shared_fixture("mcp-contract")
SUCCESS_SCHEMA: dict[str, Any] = CONTRACT["success_schema"]
EXAMPLES: list[dict[str, Any]] = CONTRACT["examples"]
INVALID_EXAMPLES: list[dict[str, Any]] = CONTRACT["invalid_examples"]

READER_KEY = f"{API_KEY}-reader"
AUTH_HEADERS = {"X-API-Key": API_KEY}
TOOLS = ("revenue", "run_sql", "describe_table")


@pytest.fixture(scope="module")
def demo_server(tmp_path_factory: pytest.TempPathFactory) -> Iterator[str]:
    yield from _serve_demo(tmp_path_factory)


@pytest.fixture(scope="module")
def proxy_server(tmp_path_factory: pytest.TempPathFactory) -> Iterator[str]:
    yield from _serve_demo(tmp_path_factory, proxy=True)


def test_connect_entrypoint_delegates_auth_to_its_proxy(proxy_server: str) -> None:
    response = httpx.get(f"{proxy_server}/v1/catalog")
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "private, no-store"
    session = RemoteSession(
        mcp_server(
            "sales",
            f"{proxy_server}/mcp/",
            auth={"headers": {"Authorization": "Key verified-by-proxy"}},
            tools=TOOLS,
        )
    )
    try:
        assert session.catalog == response.json()
        assert {entry.kind for entry in session.corpus} == {
            "schema",
            "prose",
            "definition",
        }
        result = session.submit(session.call("revenue", {})).result(timeout=10)
        assert result["data"] == {"revenue": 180000, "currency": "USD"}
        assert result["commons"]["provenance_tag"] == "A"
        sql = session.submit(
            session.call(
                "run_sql",
                {"source": "warehouse", "sql": "SELECT COUNT(*) FROM orders"},
            )
        ).result(timeout=10)
        assert sql["data"]["rows"] == [[480]]
        assert sql["commons"]["provenance_tag"] == "B"
    finally:
        session.close()


def _new_agent(
    base_url: str,
    responses: Iterable[Sequence[Any]] = (),
    *,
    api_key: str = API_KEY,
    tools: Sequence[str] = TOOLS,
) -> Commons:
    server = mcp_server(
        name="sales",
        url=f"{base_url}/mcp/",
        auth={"headers": {"X-API-Key": api_key}},
        tools=tools,
    )
    return Commons(
        scripted_chat(responses),
        semantic_layer=semantic_layer(mcp_servers=[server]),
    )


def test_remote_restore_does_not_announce_a_python_worker(demo_server: str) -> None:
    agent = _new_agent(demo_server, [text("Answer.")])
    try:
        agent.queue_restore_reminder()
        agent.chat("Continue the conversation.", echo="none")

        assert not agent._restore_reminder_pending
        assert not any(
            isinstance(content, ContentTurnReminder)
            for content in agent.get_turns()[0].contents
        )
    finally:
        agent.close()


def _remote_pair(agent: Commons, name: str) -> tuple[Tool, Tool]:
    alias = f"sales__{name}"
    return next(pair for pair in agent._remote_tools if pair[0].name == alias)


def _tool_results(agent: Commons) -> list[ContentToolResult]:
    return [
        content
        for turn in agent.get_turns()
        for content in turn.contents
        if isinstance(content, ContentToolResult)
    ]


@pytest.fixture
def remote_agent(demo_server: str) -> Iterator[Commons]:
    agent = _new_agent(demo_server)
    try:
        yield agent
    finally:
        agent.close()


def test_shared_envelope_examples_match_allowed_kinds_and_tags() -> None:
    assert CONTRACT["execution_kinds"] == _TAGS
    assert {case["name"] for case in EXAMPLES} == {
        "approved revenue calculation",
        "custom SQL result",
        "metadata result",
    }
    assert SUCCESS_SCHEMA["required"] == ["data", "commons"]
    validator = _validator(SUCCESS_SCHEMA)

    for case in EXAMPLES:
        validator.validate(case["envelope"])

    for case in INVALID_EXAMPLES:
        assert validator.is_valid(case["envelope"]) is case["schema_valid"]


def test_shared_schema_rejects_empty_revision_or_tool_identity() -> None:
    validator = _validator(SUCCESS_SCHEMA)
    for field in ("catalog_revision", "tool_id"):
        envelope = deepcopy(EXAMPLES[0]["envelope"])
        envelope["commons"][field] = ""
        assert not validator.is_valid(envelope)


def test_remote_schema_rejects_external_references_and_unknown_keywords() -> None:
    with pytest.raises(ValueError, match="External JSON Schema references"):
        _validator(
            {
                "type": "object",
                "properties": {"value": {"$ref": "https://example.test/schema.json"}},
            }
        )

    with pytest.raises(ValueError, match="Unsupported remote JSON Schema"):
        _validator(
            {
                "type": "object",
                "properties": {"value": {"type": "string", "format": "email"}},
            }
        )


def test_envelope_tags_retain_the_shared_answer_classification() -> None:
    assert CONTRACT["exchanges"]
    tags = {
        case["envelope"]["commons"]["tool_id"]: case["envelope"]["commons"][
            "provenance_tag"
        ]
        for case in EXAMPLES
    }
    for exchange in CONTRACT["exchanges"]:
        received = [tags[tool] for tool in exchange["tools"] if tags[tool] is not None]
        assert (
            derive_provenance_tag(received, exchange["verified"])
            == exchange["expected_tag"]
        )


def test_remote_session_rejects_stale_and_spoofed_envelopes() -> None:
    example = EXAMPLES[0]["envelope"]
    metadata = example["commons"]
    session = RemoteSession.__new__(RemoteSession)
    session.revision = metadata["catalog_revision"]
    session.sources = {"warehouse"}
    session.resources = {evidence["uri"]: evidence for evidence in metadata["evidence"]}
    record = {"execution_kind": "trusted_calculation"}

    session._validate_envelope("revenue", record, example)

    for field, value in (
        ("contract_version", "2"),
        ("catalog_revision", "sales-r18"),
        ("tool_id", "run_sql"),
        ("execution_kind", "ad_hoc_sql"),
        ("provenance_tag", "B"),
        ("sources", ["other"]),
    ):
        spoofed = deepcopy(example)
        spoofed["commons"][field] = value
        with pytest.raises(ValueError):
            session._validate_envelope("revenue", record, spoofed)

    stale_evidence = deepcopy(example)
    stale_evidence["commons"]["evidence"][0]["revision"] = "sales-r16"
    with pytest.raises(ValueError, match="Evidence"):
        session._validate_envelope("revenue", record, stale_evidence)


def test_rest_and_mcp_catalogs_and_resources_match(
    remote_agent: Commons, demo_server: str
) -> None:
    session = remote_agent._remote[0]
    response = httpx.get(f"{demo_server}/v1/catalog", headers=AUTH_HEADERS)
    assert response.status_code == 200
    assert response.json() == session.catalog

    listed = session.submit(session.client.list_tools()).result(timeout=10)
    rest_tools = {tool["name"]: tool for tool in response.json()["tools"]}
    mcp_tools = {tool.name: tool for tool in listed}
    assert set(rest_tools) == set(mcp_tools) == set(TOOLS)
    for name, rest_tool in rest_tools.items():
        assert mcp_tools[name].inputSchema == rest_tool["inputSchema"]
        assert mcp_tools[name].outputSchema == rest_tool["outputSchema"]

    measures = httpx.get(f"{demo_server}/v1/measures", headers=AUTH_HEADERS)
    assert measures.status_code == 200
    assert [tool["name"] for tool in measures.json()["measures"]] == ["revenue"]

    resources = (
        (
            "/v1/data-dictionaries/warehouse",
            "commons://sources/warehouse/data-dict.yaml",
        ),
        ("/v1/contexts/revenue-policy", "commons://contexts/revenue-policy"),
    )
    for route, uri in resources:
        rest_resource = httpx.get(f"{demo_server}{route}", headers=AUTH_HEADERS)
        assert rest_resource.status_code == 200
        assert rest_resource.text == session.submit(session._resource_text(uri)).result(
            timeout=10
        )
        assert rest_resource.headers["X-Commons-Catalog-Revision"] == session.revision


def test_reader_credentials_filter_the_same_rest_and_mcp_catalogs(
    demo_server: str,
) -> None:
    agent = _new_agent(
        demo_server,
        api_key=READER_KEY,
        tools=("revenue", "describe_table"),
    )
    try:
        session = agent._remote[0]
        response = httpx.get(
            f"{demo_server}/v1/catalog",
            headers={"X-API-Key": READER_KEY},
        )
        assert response.status_code == 200
        assert response.json() == session.catalog
        assert {tool["name"] for tool in response.json()["tools"]} == {
            "revenue",
            "describe_table",
        }
        assert response.json()["sources"][0]["sql_enabled"] is False

        listed = session.submit(session.client.list_tools()).result(timeout=10)
        assert {tool.name for tool in listed} == {"revenue", "describe_table"}

        denied = session.submit(
            session.client.call_tool(
                "run_sql",
                {"source": "warehouse", "sql": "SELECT 1"},
                meta={"commons_catalog_revision": session.revision},
                raise_on_error=False,
            )
        ).result(timeout=10)
        assert denied.is_error
    finally:
        agent.close()


def test_rest_and_mcp_both_reject_missing_authentication(demo_server: str) -> None:
    rest = httpx.get(f"{demo_server}/v1/catalog")
    mcp = httpx.post(
        f"{demo_server}/mcp/",
        headers={
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        },
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "commons-test", "version": "1"},
            },
        },
    )
    assert rest.status_code == mcp.status_code == 401


def test_actual_tool_envelopes_validate_against_the_shared_schema(
    remote_agent: Commons,
) -> None:
    session = remote_agent._remote[0]
    calls = (
        (
            "revenue",
            {"region": "North"},
            "trusted_calculation",
            {"revenue": 250.0, "currency": "USD"},
        ),
        (
            "run_sql",
            {
                "source": "warehouse",
                "sql": (
                    "SELECT region, SUM(revenue) AS total FROM orders "
                    "GROUP BY region ORDER BY region"
                ),
            },
            "ad_hoc_sql",
            {
                "columns": ["region", "total"],
                "rows": [["North", 250.0], ["South", 250.0]],
            },
        ),
        (
            "describe_table",
            {"source": "warehouse", "table": "orders"},
            "metadata",
            None,
        ),
    )
    validator = _validator(SUCCESS_SCHEMA)

    for name, arguments, kind, expected_data in calls:
        envelope = session.submit(session.call(name, arguments)).result(timeout=10)
        validator.validate(envelope)
        metadata = envelope["commons"]
        assert metadata["tool_id"] == name
        assert metadata["execution_kind"] == kind
        assert metadata["provenance_tag"] == CONTRACT["execution_kinds"][kind]
        if expected_data is not None:
            assert envelope["data"] == expected_data
    schema = session.submit(
        session.call("describe_table", {"source": "warehouse", "table": "orders"})
    ).result(timeout=10)["data"]["schema"]
    assert [column[0] for column in schema] == ["order_id", "region", "revenue"]


def test_remote_revenue_preserves_alias_schema_and_sync_async_calls(
    remote_agent: Commons,
) -> None:
    session = remote_agent._remote[0]
    asynchronous, synchronous = _remote_pair(remote_agent, "revenue")
    input_schema = session.records["revenue"]["inputSchema"]

    assert asynchronous.name == synchronous.name == "sales__revenue"
    assert asynchronous.schema == synchronous.schema
    assert asynchronous.schema["function"]["parameters"] == input_schema
    assert inspect.iscoroutinefunction(asynchronous.func)
    assert not inspect.iscoroutinefunction(synchronous.func)
    assert remote_agent._sources == {}
    assert remote_agent._python is None
    registered = next(
        tool
        for tool in remote_agent.get_tools()
        if isinstance(tool, Tool) and tool.name == "sales__revenue"
    )
    assert registered.func is asynchronous.func

    north = synchronous.func(region="North")
    all_regions = asyncio.run(asynchronous.func())
    for result, amount in ((north, 250.0), (all_regions, 500.0)):
        assert isinstance(result, ContentToolResult)
        assert json.loads(result.value)["revenue"] == amount
        assert result.extra[TAG_EXTRA_KEY] == Tag.A


def test_sync_chat_restores_the_async_remote_tool(demo_server: str) -> None:
    request = ContentToolRequest(
        id="call-revenue",
        name="sales__revenue",
        arguments={"region": "North"},
    )
    agent = _new_agent(demo_server, [[request], text("North revenue is $250.")])
    try:
        asynchronous, _ = _remote_pair(agent, "revenue")
        agent.chat("What is North revenue?", stream=False, echo="none")
        (result,) = _tool_results(agent)
        assert result.extra[TAG_EXTRA_KEY] == Tag.A
        assert json.loads(result.value)["revenue"] == 250.0
        registered = next(
            tool
            for tool in agent.get_tools()
            if isinstance(tool, Tool) and tool.name == "sales__revenue"
        )
        assert registered.func is asynchronous.func
    finally:
        agent.close()


async def test_sql_result_is_cited_through_a_real_commons_chat(
    demo_server: str,
) -> None:
    request = ContentToolRequest(
        id="call-run-sql",
        name="sales__run_sql",
        arguments={
            "source": "warehouse",
            "sql": "SELECT SUM(revenue) AS total_revenue FROM orders",
        },
    )
    agent = _new_agent(demo_server)
    try:
        policy = next(
            entry.text
            for entry in agent._remote[0].corpus
            if entry.label == "revenue-policy"
        )
        quote = policy.split(". ", 1)[0] + "."
        answer = (
            "Total revenue is $500.\n\n"
            "<commons-citation>\n\nThe policy describes the calculation.\n\n"
            f"> {quote}\n\n</commons-citation>"
        )
        cast(ScriptedProvider, agent.provider).responses = [[request], text(answer)]
        chunks = [
            chunk async for chunk in await agent.stream_async("What is total revenue?")
        ]
        rendered = "".join(chunk for chunk in chunks if isinstance(chunk, str))
        (result,) = _tool_results(agent)
        returned_data = json.loads(result.value.partition("\n\n")[0])

        assert returned_data == {
            "columns": ["total_revenue"],
            "rows": [[500.0]],
        }
        assert result.extra[TAG_EXTRA_KEY] == Tag.B
        assert result.extra["commons_remote"]["tool_id"] == "run_sql"
        assert quote in rendered
        assert '<shiny-aside label="revenue-policy"' in rendered
        assert "<commons-citation>" not in rendered
        assert 'label="Untrusted"' not in rendered
    finally:
        agent.close()


def test_rejected_sql_leaves_the_duckdb_orders_intact(remote_agent: Commons) -> None:
    session = remote_agent._remote[0]
    with pytest.raises(ValueError, match="returned an error"):
        session.submit(
            session.call(
                "run_sql",
                {"source": "warehouse", "sql": "DROP TABLE orders"},
            )
        ).result(timeout=10)

    intact = session.submit(
        session.call(
            "run_sql",
            {
                "source": "warehouse",
                "sql": (
                    "SELECT COUNT(*) AS order_count, SUM(revenue) AS total FROM orders"
                ),
            },
        )
    ).result(timeout=10)
    _validator(SUCCESS_SCHEMA).validate(intact)
    assert intact["data"] == {
        "columns": ["order_count", "total"],
        "rows": [[4, 500.0]],
    }


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT * FROM private_notes",
        "SELECT * FROM main.private_notes",
        "WITH orders AS (SELECT * FROM private_notes) SELECT * FROM orders",
        "SELECT * FROM orders WHERE EXISTS(SELECT * FROM private_notes)",
        "SELECT current_database()",
        "SELECT * FROM range(10)",
        "SELECT * FROM read_csv('/etc/passwd')",
        "SELECT 1; SELECT 2",
        "WITH changed AS (DELETE FROM orders RETURNING *) SELECT * FROM changed",
        "SELECT * INTO stolen FROM orders",
        "SELECT * FROM orders FOR UPDATE",
    ],
)
def test_sql_policy_rejects_unauthorized_paths(remote_agent: Commons, sql: str) -> None:
    session = remote_agent._remote[0]
    with pytest.raises(ValueError, match="returned an error"):
        session.submit(
            session.call(
                "run_sql",
                {
                    "source": "warehouse",
                    "sql": sql,
                },
            )
        ).result(timeout=10)


@pytest.mark.parametrize(
    "sql,expected",
    [
        (
            "WITH north AS (SELECT revenue FROM orders WHERE region='North') SELECT SUM(revenue) AS total FROM north",
            [[250.0]],
        ),
        (
            "SELECT region FROM orders WHERE region='North' UNION SELECT region FROM orders WHERE region='South' ORDER BY region",
            [["North"], ["South"]],
        ),
    ],
)
def test_authorized_ctes_and_set_operations(
    remote_agent: Commons,
    sql: str,
    expected: list[list[Any]],
) -> None:
    session = remote_agent._remote[0]
    result = session.submit(
        session.call(
            "run_sql",
            {
                "source": "warehouse",
                "sql": sql,
            },
        )
    ).result(timeout=10)
    assert result["data"]["rows"] == expected
    assert result["commons"]["provenance_tag"] == "B"


def test_partial_results_declare_row_and_byte_bounds(remote_agent: Commons) -> None:
    session = remote_agent._remote[0]
    rows = session.submit(
        session.call(
            "run_sql",
            {
                "source": "warehouse",
                "sql": "SELECT a.order_id FROM orders a CROSS JOIN orders b CROSS JOIN orders c CROSS JOIN orders d",
            },
        )
    ).result(timeout=10)
    assert len(rows["data"]["rows"]) == 100
    assert rows["commons"]["coverage"]["truncated"] is True
    payload = "x" * 40_000
    byte_limited = session.submit(
        session.call(
            "run_sql",
            {
                "source": "warehouse",
                "sql": f"SELECT '{payload}' AS payload FROM orders",
            },
        )
    ).result(timeout=10)
    assert byte_limited["data"]["rows"] == [[payload]]
    assert byte_limited["commons"]["coverage"]["truncated"] is True
    assert byte_limited["commons"]["provenance_tag"] == "B"


def test_database_deadline_interrupts_an_expensive_query(remote_agent: Commons) -> None:
    session = remote_agent._remote[0]
    started = time.monotonic()
    with pytest.raises(ValueError, match="returned an error"):
        session.submit(
            session.call(
                "run_sql",
                {
                    "source": "warehouse",
                    "sql": "WITH RECURSIVE t(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM t WHERE n<100000000) SELECT SUM(n) FROM t",
                },
            )
        ).result(timeout=10)
    assert time.monotonic() - started < 10
    result = session.submit(session.call("revenue", {})).result(timeout=10)
    assert result["data"]["revenue"] == 500


def test_revision_metadata_cannot_execute_a_stale_catalog(
    remote_agent: Commons,
) -> None:
    session = remote_agent._remote[0]
    reply = session.submit(
        session.client.call_tool(
            "revenue",
            {},
            meta={"commons_catalog_revision": "stale"},
            raise_on_error=False,
        )
    ).result(timeout=10)
    assert reply.is_error


def test_configured_views_cannot_expose_unlisted_tables(tmp_path: Path) -> None:
    import duckdb

    from commons.server import Registry

    database = tmp_path / "view.duckdb"
    with duckdb.connect(str(database)) as connection:
        connection.execute("CREATE TABLE private_orders AS SELECT 1 AS secret")
        connection.execute("CREATE VIEW orders AS SELECT * FROM private_orders")
    with pytest.raises(ValueError, match="base tables"):
        Registry(database, semantic_layer(), "", {})


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT '" + "x" * 65_537 + "'",
        "SELECT " + "+".join(["1"] * 1100),
        "SELECT " + "(" * 33 + "1" + ")" * 33,
    ],
)
def test_parser_budgets_fail_before_database_execution(
    remote_agent: Commons, sql: str
) -> None:
    session = remote_agent._remote[0]
    reply = session.submit(
        session.client.call_tool(
            "run_sql",
            {"source": "warehouse", "sql": sql},
            meta={"commons_catalog_revision": session.revision},
            raise_on_error=False,
        )
    ).result(timeout=10)
    assert reply.is_error


def test_configuration_is_immutable_and_annotations_resolve() -> None:
    headers = {"X-API-Key": "a-dummy-key"}
    config = mcp_server(
        "sales",
        "http://127.0.0.1:65534/mcp/",
        auth={"headers": headers},
        tools=["revenue"],
    )
    headers["X-API-Key"] = "changed"
    assert config.headers["X-API-Key"] == "a-dummy-key"
    assert "a-dummy-key" not in repr(config)
    assert get_type_hints(semantic_layer)["mcp_servers"]
    with pytest.raises(ValueError, match="HTTPS"):
        MCPServer("sales", "http://example.com/mcp/", headers, ["revenue"])


def test_alias_collisions_across_servers_are_rejected() -> None:
    auth = {"headers": AUTH_HEADERS}
    first = mcp_server("a", "http://127.0.0.1:65534/mcp/", auth=auth, tools=["b__c"])
    second = mcp_server("a__b", "http://127.0.0.1:65534/mcp/", auth=auth, tools=["c"])
    with pytest.raises(ValueError, match="aliases"):
        semantic_layer(mcp_servers=[first, second])


def test_catalog_schema_comparison_distinguishes_booleans_and_numbers(
    remote_agent: Commons,
) -> None:
    session = remote_agent._remote[0]
    listed = {
        tool.name: tool
        for tool in session.submit(session.client.list_tools()).result(timeout=10)
    }
    session.records["revenue"]["inputSchema"]["properties"]["flag"] = {"enum": [True]}
    listed["revenue"].inputSchema["properties"]["flag"] = {"enum": [1]}
    with pytest.raises(ValueError, match="schemas disagree"):
        session._check_descriptors(listed)


def test_nested_cells_are_checked_before_json_serialization() -> None:
    from commons.server._registry import (
        _bounded_json,
        _check_value_budget,
        _OutputLimit,
    )

    with pytest.raises(_OutputLimit):
        _check_value_budget({"nested": [["x" * 65_000]]}, 64_000)
    with pytest.raises(_OutputLimit):
        _bounded_json(["\x00"] * 16, 40)
    assert json.loads(_bounded_json({"nested": [[1, 2], None]}, 100)) == {
        "nested": [[1, 2], None]
    }


def test_struct_literals_count_toward_the_sql_depth_budget() -> None:
    from commons.server._registry import _check_sql_budget

    sql = "SELECT " + "{'x':" * 33 + "1" + "}" * 33
    with pytest.raises(ValueError, match="nesting"):
        _check_sql_budget(sql)

"""Real transport checks for explicit authentication and source grants."""

from __future__ import annotations

import importlib
from collections.abc import Iterator
from typing import Any, cast

import httpx
import pytest

from commons import mcp_server
from commons._mcp import RemoteSession
from commons.server import Grant, create_app

from ._mcp_server import API_KEY, PACKAGE_ROOT, _serve_demo


@pytest.fixture(scope="module")
def scoped_server(tmp_path_factory: pytest.TempPathFactory) -> Iterator[str]:
    yield from _serve_demo(tmp_path_factory, datasets=True)


@pytest.fixture(scope="module")
def reader(scoped_server: str) -> Iterator[RemoteSession]:
    session = RemoteSession(
        mcp_server(
            "reader",
            scoped_server + "/mcp/",
            auth={"headers": {"X-API-Key": API_KEY + "-reader"}},
            tools=["revenue", "describe_table"],
        )
    )
    try:
        yield session
    finally:
        session.close()


def _raw_call(session: RemoteSession, name: str, args: dict[str, Any]) -> Any:
    return session.submit(
        session.client.call_tool(
            name,
            args,
            meta={"commons_catalog_revision": session.revision},
            raise_on_error=False,
        )
    ).result(timeout=10)


def test_missing_key_and_proxy_mode_require_explicit_configuration(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.syspath_prepend(str(PACKAGE_ROOT / "examples/connect-mcp"))
    demo = importlib.import_module("demo")
    with pytest.raises(ValueError, match="credentials|proxy"):
        demo.create_demo_app()
    app = demo.create_demo_app("test-admin")
    with pytest.raises(ValueError, match="credentials|proxy"):
        create_app(app.state.registry)
    with pytest.raises(ValueError, match="not both"):
        create_app(app.state.registry, api_keys={}, trust_proxy=True)
    with pytest.raises(TypeError, match="explicit boolean"):
        create_app(app.state.registry, trust_proxy="false")  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="nonempty"):
        create_app(app.state.registry, api_keys={" ": Grant(frozenset(), frozenset())})
    with pytest.raises(TypeError, match="Grant"):
        create_app(app.state.registry, api_keys={"key": frozenset({"revenue"})})  # type: ignore[dict-item]
    with pytest.raises(ValueError, match="unknown tools or sources"):
        create_app(
            app.state.registry,
            api_keys={"key": Grant(frozenset({"revenue"}), frozenset({"unknown"}))},
        )
    trusted = create_app(app.state.registry, trust_proxy=True)
    assert (
        trusted.docs_url is None
        and trusted.redoc_url is None
        and trusted.openapi_url is None
    )


def test_service_rejects_defaults_and_disables_documentation(
    scoped_server: str,
) -> None:
    for headers in ({}, {"X-API-Key": "demo-secret"}):
        assert (
            httpx.get(scoped_server + "/v1/catalog", headers=headers).status_code == 401
        )
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert (
            httpx.get(scoped_server + path, headers={"X-API-Key": API_KEY}).status_code
            == 404
        )


@pytest.mark.asyncio
async def test_mutating_caller_sets_cannot_widen_grants(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.syspath_prepend(str(PACKAGE_ROOT / "examples/connect-mcp"))
    demo = importlib.import_module("demo")
    fixture = demo.create_demo_app(
        "test-admin",
        hospital_data=PACKAGE_ROOT
        / "examples/connect-mcp/data/hospital_events.parquet",
    )
    tools = {"revenue"}
    sources = {"warehouse"}
    app = create_app(
        fixture.state.registry,
        api_keys={"reader": Grant(cast(Any, tools), cast(Any, sources))},
    )
    tools.add("run_sql")
    sources.add("hospital")
    async with (
        fixture.router.lifespan_context(fixture),
        httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
            headers={"X-API-Key": "reader"},
        ) as client,
    ):
        response = await client.get("/v1/catalog")
        assert response.status_code == 200
        catalog = response.json()
        assert {tool["name"] for tool in catalog["tools"]} == {"revenue"}
        assert {source["id"] for source in catalog["sources"]} == {"warehouse"}
        assert (await client.get("/v1/data-dictionaries/hospital")).status_code == 404


def test_reader_catalog_and_direct_resources_hide_hospital(
    scoped_server: str, reader: RemoteSession
) -> None:
    headers = {"X-API-Key": API_KEY + "-reader"}
    response = httpx.get(scoped_server + "/v1/catalog", headers=headers)
    assert response.json() == reader.catalog
    assert [source["id"] for source in reader.catalog["sources"]] == ["warehouse"]
    assert "hospital" not in response.text
    assert (
        "hospital"
        not in httpx.get(scoped_server + "/v1/contexts", headers=headers).text
    )
    listed = reader.submit(reader.client.list_resources()).result(timeout=10)
    assert {str(resource.uri) for resource in listed} == {
        "commons://catalog",
        *reader.resources,
    }
    for route, uri in (
        ("/v1/data-dictionaries/hospital", "commons://sources/hospital/data-dict.yaml"),
        ("/v1/contexts/hospital-policy", "commons://contexts/hospital-policy"),
    ):
        assert httpx.get(scoped_server + route, headers=headers).status_code == 404
        with pytest.raises(Exception, match="resource|Resource"):
            reader.submit(reader.client.read_resource(uri)).result(timeout=10)


def test_describe_is_a_raw_row_grant_only_for_the_granted_source(
    reader: RemoteSession,
) -> None:
    result = reader.submit(
        reader.call("describe_table", {"source": "warehouse", "table": "orders"})
    ).result(timeout=10)
    assert len(result["data"]["sample"]["rows"]) == 5
    assert result["commons"]["sources"] == ["warehouse"]
    denied = _raw_call(
        reader, "describe_table", {"source": "hospital", "table": "hospital_events"}
    )
    assert denied.is_error
    assert "cannot access the requested source" in "\n".join(
        part.text for part in denied.content
    )
    missing = _raw_call(reader, "hospital_summary", {})
    assert missing.is_error

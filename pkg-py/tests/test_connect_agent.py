"""The actual Connect entry point sends auth and isolates session lifetimes."""

from __future__ import annotations

import importlib
import json
from collections.abc import Callable, Iterator
from typing import Any

import httpx
import pytest

pytest.importorskip("shinychat")
pytest.importorskip("anthropic")

from chatlas import Tool
from shiny.session import session_context

from ._mcp_server import PROXY_KEY, _serve_demo
from ._session import IdleSession


@pytest.fixture(scope="module")
def connect_proxy_server(tmp_path_factory: pytest.TempPathFactory) -> Iterator[str]:
    yield from _serve_demo(tmp_path_factory, proxy=True, verify_proxy_auth=True)


class EndSession(IdleSession):
    def __init__(self) -> None:
        super().__init__()
        self.end_callbacks: list[Callable[[], Any]] = []

    def on_ended(self, fn: Callable[[], Any]) -> Callable[[], None]:
        self.end_callbacks.append(fn)
        return lambda: None


def _agent_module(base_url: str, monkeypatch: pytest.MonkeyPatch) -> Any:
    monkeypatch.setenv("COMMONS_MCP_URL", base_url + "/mcp/")
    monkeypatch.setenv("CONNECT_API_KEY", PROXY_KEY)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "unused-by-this-no-model-call-test")
    return importlib.import_module("examples.connect-agent.app")


def _revenue_tool(agent: Any) -> Any:
    return next(
        tool
        for tool in agent.get_tools()
        if isinstance(tool, Tool) and tool.name == "sales__revenue"
    )


@pytest.mark.asyncio
async def test_connect_sessions_send_auth_and_close_independently(
    connect_proxy_server: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = _agent_module(connect_proxy_server, monkeypatch)
    first, second = EndSession(), EndSession()
    try:
        with session_context(first):
            chat1 = module.server(first.input, first.output, first)
        with session_context(second):
            chat2 = module.server(second.input, second.output, second)
        assert chat1.client.value is not chat2.client.value
        first_tool = _revenue_tool(chat1.client.value)
        second_tool = _revenue_tool(chat2.client.value)
        assert "run_python" not in {
            tool.name for tool in chat1.client.value.get_tools()
        }
        assert len(first.end_callbacks) == len(second.end_callbacks) == 1
        first.end_callbacks[0]()
        with pytest.raises(RuntimeError, match="closed"):
            await first_tool.func()
        result = await second_tool.func()
        assert json.loads(result.value) == {"revenue": 180000, "currency": "USD"}
    finally:
        for session in (first, second):
            for callback in session.end_callbacks:
                callback()
    with pytest.raises(RuntimeError, match="closed"):
        await second_tool.func()


def test_connect_agent_rejects_an_incorrect_proxy_key(
    connect_proxy_server: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = _agent_module(connect_proxy_server, monkeypatch)
    assert httpx.get(connect_proxy_server + "/v1/catalog").status_code == 401
    monkeypatch.setenv("CONNECT_API_KEY", "incorrect-key")
    session = EndSession()
    with session_context(session), pytest.raises(RuntimeError, match="initialize MCP"):
        module.server(session.input, session.output, session)

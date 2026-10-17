"""System prompt composition for agents backed by remote capabilities."""

from __future__ import annotations

from collections.abc import Iterator

import pandas as pd
import pytest

import commons._agent as agent_module
from commons import Commons, DataSource, data_source, mcp_server, semantic_layer

from ._mcp_server import PROXY_KEY, _serve_demo
from ._provider import scripted_chat


@pytest.fixture(scope="module")
def demo_server(tmp_path_factory: pytest.TempPathFactory) -> Iterator[str]:
    yield from _serve_demo(tmp_path_factory, proxy=True)


def _remote_agent(
    base_url: str,
    instructions: str | None = None,
    data_sources: DataSource | None = None,
) -> Commons:
    server = mcp_server(
        name="sales",
        url=f"{base_url}/mcp/",
        auth={"headers": {"Authorization": f"Key {PROXY_KEY}"}},
        tools=("revenue",),
    )
    return Commons(
        scripted_chat(),
        data_sources=data_sources,
        semantic_layer=semantic_layer(mcp_servers=[server]),
        instructions=instructions,
    )


def test_remote_agent_prompt_keeps_base_and_remote_guidance(
    demo_server: str,
) -> None:
    agent = _remote_agent(demo_server, "Use fiscal-year conventions.")
    try:
        prompt = agent.system_prompt
        assert prompt is not None
        assert prompt.startswith("Your task is to thoughtfully and accurately")
        assert "## Remote capabilities" in prompt
        assert prompt.index("## Remote capabilities") < prompt.index(
            "## Additional instructions"
        )
        assert prompt.endswith(
            "## Additional instructions\n\nUse fiscal-year conventions."
        )
        assert "run_python" not in prompt
    finally:
        agent.close()


def test_remote_agent_omits_empty_additional_instructions(
    demo_server: str,
) -> None:
    agent = _remote_agent(demo_server)
    try:
        prompt = agent.system_prompt
        assert prompt is not None
        assert "Your task is to thoughtfully and accurately" in prompt
        assert "## Remote capabilities" in prompt
        assert "## Additional instructions" not in prompt
        assert "run_python" not in prompt
    finally:
        agent.close()


def test_hybrid_agent_places_additional_instructions_after_remote_capabilities(
    demo_server: str,
) -> None:
    source = data_source(sales=pd.DataFrame({"revenue": [500.0]}))
    agent = _remote_agent(
        demo_server, "Use fiscal-year conventions.", data_sources=source
    )
    try:
        prompt = agent.system_prompt
        assert prompt is not None
        assert prompt.index("## Remote capabilities") < prompt.index(
            "## Additional instructions"
        )
        assert prompt.endswith(
            "## Additional instructions\n\nUse fiscal-year conventions."
        )
        assert "run_python" in prompt
    finally:
        agent.close()


def test_remote_initialization_error_survives_cleanup_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    initialization_error = ValueError("remote initialization failed")
    cleanup_error = RuntimeError("cleanup failed")

    def fail_open(_servers: object) -> None:
        raise initialization_error

    def fail_close(_servers: object) -> None:
        raise cleanup_error

    monkeypatch.setattr(agent_module, "open_servers", fail_open)
    monkeypatch.setattr(agent_module, "close_servers", fail_close)
    server = mcp_server(
        "sales",
        "https://example.test/mcp",
        auth={"headers": {"Authorization": "Key test"}},
        tools=("revenue",),
    )

    with pytest.raises(ValueError) as error:
        Commons(scripted_chat(), semantic_layer=semantic_layer(mcp_servers=[server]))

    assert error.value is initialization_error

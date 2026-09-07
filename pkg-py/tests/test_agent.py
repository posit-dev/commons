"""Building an agent: what it validates, what it assembles, and what it warms."""

from pathlib import Path
from typing import Annotated, Any

import pandas as pd
import pytest
from chatlas import Chat, ContentToolResult, Tool, UserTurn
from pydantic import Field

from commons import Injected, context_layer, data_source, measure, semantic_layer
from commons._agent import Commons
from commons._citations import CorpusEntry

from ._provider import ScriptedProvider, scripted_chat, text

DICTIONARY = """
name: sales
description: What the shop sold.
tables:
  - name: sales
    description: One row per order line.
    columns:
      - name: revenue
        type: number
        description: Line revenue.
      - name: region
        type: string
"""


def frame() -> pd.DataFrame:
    return pd.DataFrame(
        {"revenue": [500.0, 900.0, 300.0], "region": ["EMEA", "Americas", "EMEA"]}
    )


@pytest.fixture
def source() -> Any:
    return data_source(sales=frame())


@pytest.fixture
def client() -> Chat:
    return scripted_chat()


# The agent builds its own chat, so what it registered and what it tells the
# model are read off the agent rather than off the client it was given.
def tool_names(agent: Commons) -> list[str]:
    return [tool.name for tool in agent._client.get_tools()]


def prompt(agent: Commons) -> str:
    system_prompt = agent._client.system_prompt
    assert system_prompt is not None
    return system_prompt


def agent_tool(agent: Commons, name: str) -> Tool:
    tool = next(tool for tool in agent._client.get_tools() if tool.name == name)
    assert isinstance(tool, Tool)
    return tool


def call_tool(agent: Commons, tool: str, /, **arguments: Any) -> str:
    result = agent_tool(agent, tool).func(**arguments)
    assert isinstance(result, ContentToolResult)
    assert isinstance(result.value, str)
    return result.value


# ---- validation -----------------------------------------------------------


def test_the_client_has_to_be_a_chat(source: Any) -> None:
    with pytest.raises(TypeError, match="chatlas.Chat"):
        Commons("not a chat", source)  # type: ignore[arg-type]


def test_data_sources_has_to_hold_data_sources(client: Chat) -> None:
    with pytest.raises(TypeError, match="commons.data_source"):
        Commons(client, "sales")  # type: ignore[arg-type]

    with pytest.raises(TypeError, match="warehouse is not"):
        Commons(client, {"warehouse": frame()})  # type: ignore[dict-item]


def test_an_agent_needs_at_least_one_data_source(client: Chat) -> None:
    with pytest.raises(ValueError, match="at least one DataSource"):
        Commons(client, {})


def test_the_layers_have_to_be_layers(client: Chat, source: Any) -> None:
    with pytest.raises(TypeError, match="commons.context_layer"):
        Commons(client, source, context_layer="notes.md")  # type: ignore[arg-type]

    with pytest.raises(TypeError, match="commons.semantic_layer"):
        Commons(client, source, semantic_layer=[])  # type: ignore[arg-type]


def test_instructions_naming_a_missing_file_fail_at_construction(
    client: Chat, source: Any, tmp_path: Path
) -> None:
    with pytest.raises(FileNotFoundError):
        Commons(client, source, instructions=str(tmp_path / "absent.md"))


def test_a_system_prompt_on_the_client_warns_and_is_ignored(
    client: Chat, source: Any
) -> None:
    client.system_prompt = "You are a pirate."

    with pytest.warns(UserWarning, match="system prompt"):
        agent = Commons(client, source)

    assert "pirate" not in prompt(agent)


def test_the_clients_history_warns_and_does_not_carry_over(
    client: Chat, source: Any
) -> None:
    client.add_turn(UserTurn("An earlier question."))

    with pytest.warns(UserWarning, match="set_turns"):
        agent = Commons(client, source)

    assert agent.get_turns() == []
    assert len(client.get_turns()) == 1


# ---- the agent's own chat -------------------------------------------------


def test_the_client_it_was_given_is_left_alone(client: Chat, source: Any) -> None:
    agent = Commons(client, source)

    # The agent brings its own tools and prompt, and someone else may still be
    # holding this object, so none of that reaches it.
    assert client.get_tools() == []
    assert client.system_prompt is None
    assert tool_names(agent)
    assert agent._client is not client


def test_model_parameters_carry_onto_the_agents_chat(client: Chat, source: Any) -> None:
    client.set_model_params(temperature=0.0, seed=7)

    agent = Commons(client, source)

    # Reading chatlas' own attribute is the only way to see these, and doing
    # it here on purpose means a chatlas that renames it fails loudly rather
    # than leaving the warning path as the only thing still exercised.
    assert agent._client._standard_model_params == {"temperature": 0.0, "seed": 7}


def test_model_parameters_that_cannot_be_read_are_reported(
    client: Chat, source: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    client.set_model_params(temperature=0.0)
    # chatlas has a setter and no getter, so the values are read off the
    # attribute behind it; a chatlas that renames it says so rather than
    # dropping a temperature in silence.
    monkeypatch.delattr(client, "_standard_model_params")

    with pytest.warns(UserWarning, match="set_model_params"):
        Commons(client, source)


def test_the_provider_arguments_and_conversation_id_carry_over(
    client: Chat, source: Any
) -> None:
    client.kwargs_chat = {"max_tokens": 2048}  # type: ignore[typeddict-unknown-key]
    client.conversation_id = "abc123"

    agent = Commons(client, source)
    client.kwargs_chat["max_tokens"] = 8  # type: ignore[typeddict-unknown-key]

    assert agent._client.kwargs_chat == {"max_tokens": 2048}
    assert agent._client.conversation_id == "abc123"
    # The provider carries the model, so it is shared on purpose.
    assert agent._client.provider is client.provider


# ---- assembly -------------------------------------------------------------


def test_an_agent_registers_the_tools_its_composition_earns(
    client: Chat, source: Any
) -> None:
    agent = Commons(client, source)

    # Which conditions earn which tool is pinned by
    # tests/shared/tool-registration.json; what matters here is that the
    # agent's own composition is what they were asked about.
    assert tool_names(agent) == ["search_context", "describe_table", "run_sql"]


def test_a_semantic_layer_earns_the_measure_tools(client: Chat, source: Any) -> None:
    @measure(description="Count orders.")
    def order_count() -> int:
        return 3

    agent = Commons(client, source, semantic_layer=semantic_layer(order_count))

    assert "search_pool" in tool_names(agent)
    assert "call_measure" in tool_names(agent)


def test_the_system_prompt_names_the_tables(client: Chat, source: Any) -> None:
    assert "- sales" in prompt(Commons(client, source))


def test_instructions_are_appended_to_the_prompt(client: Chat, source: Any) -> None:
    agent = Commons(client, source, instructions="Use fiscal-year conventions.")

    assert prompt(agent).endswith("Use fiscal-year conventions.")


def test_instructions_can_be_read_from_a_file(
    client: Chat, source: Any, tmp_path: Path
) -> None:
    path = tmp_path / "house-style.md"
    path.write_text("Round revenue to whole dollars.", encoding="utf-8")

    agent = Commons(client, source, instructions=str(path))

    assert prompt(agent).endswith("Round revenue to whole dollars.")


def test_the_prompt_describes_the_tools_the_agent_actually_has(
    client: Chat, source: Any
) -> None:
    @measure(description="Count orders.")
    def order_count() -> int:
        return 3

    with_measures = prompt(
        Commons(client, source, semantic_layer=semantic_layer(order_count))
    )
    bare = prompt(Commons(scripted_chat(), source))

    assert "call_measure" in with_measures
    assert "call_measure" not in bare


def test_the_model_decides_which_reminder_the_prompt_expects(source: Any) -> None:
    five = prompt(Commons(scripted_chat(model="claude-opus-5"), source))
    four = prompt(Commons(scripted_chat(model="claude-sonnet-4-5"), source))

    # is_claude_5_model() drives one prompt section, so the two differ.
    assert five != four


def test_the_context_layer_gains_the_sources_prose(
    client: Chat, source: Any, tmp_path: Path
) -> None:
    path = tmp_path / "data-dict.yaml"
    path.write_text(DICTIONARY, encoding="utf-8")
    documented = data_source(sales=frame(), dictionary=path)
    notes = tmp_path / "notes.md"
    notes.write_text("Revenue means booked revenue.", encoding="utf-8")
    layer = context_layer(files=[notes])

    agent = Commons(client, documented, context_layer=layer)

    assert agent._context_layer is not None
    assert agent._context_layer is not layer
    assert len(agent._context_layer.docs) > len(layer.docs)
    # The caller's layer is left as it was, so a second agent starts clean.
    assert layer.docs == ("Revenue means booked revenue.",)


def test_an_agent_with_nothing_to_retrieve_has_no_context_layer(
    client: Chat, source: Any
) -> None:
    assert Commons(client, source)._context_layer is None


def test_the_citation_corpus_holds_the_trusted_text(
    client: Chat, source: Any, tmp_path: Path
) -> None:
    notes = tmp_path / "notes.md"
    notes.write_text("Canopy cover is always acre-weighted.", encoding="utf-8")

    agent = Commons(client, source, context_layer=context_layer(files=[notes]))

    corpus = agent.citation_corpus()
    assert all(isinstance(entry, CorpusEntry) for entry in corpus)
    assert any("acre-weighted" in entry.text for entry in corpus)


def test_the_conversation_state_is_the_agents_own(client: Chat, source: Any) -> None:
    first = Commons(client, source)
    second = Commons(scripted_chat(), source)

    first._handles.register(frame())

    assert first._handles.ids() == ["r1"]
    assert second._handles.ids() == []


def test_one_handle_store_serves_every_tool_call(client: Chat, source: Any) -> None:
    agent = Commons(client, source)

    call_tool(agent, "run_sql", sql="SELECT revenue FROM sales")
    call_tool(agent, "run_sql", sql="SELECT region FROM sales")

    assert agent._handles.ids() == ["r1", "r2"]


def test_a_tables_dictionary_entry_is_delivered_once_per_conversation(
    client: Chat, tmp_path: Path
) -> None:
    path = tmp_path / "data-dict.yaml"
    path.write_text(DICTIONARY, encoding="utf-8")
    agent = Commons(client, data_source(sales=frame(), dictionary=path))

    first = call_tool(agent, "run_sql", sql="SELECT revenue FROM sales")
    second = call_tool(agent, "run_sql", sql="SELECT region FROM sales")

    assert "One row per order line." in first
    assert "One row per order line." not in second


# ---- injected measure arguments -------------------------------------------


def test_a_measure_receives_a_named_sources_connection(client: Chat) -> None:
    @measure(description="Count orders.")
    def order_count(warehouse: Injected[Any]) -> int:
        rows = warehouse.execute("SELECT count(*) AS n FROM sales").fetchall()
        return int(rows[0][0])

    agent = Commons(
        client,
        {"warehouse": data_source(sales=frame())},
        semantic_layer=semantic_layer(order_count),
    )
    result = call_tool(agent, "call_measure", name="order_count", arguments="{}")

    assert "3" in result


def test_a_measure_can_still_take_an_argument_the_model_supplies(
    client: Chat,
) -> None:
    @measure(description="Revenue for a region.")
    def region_revenue(
        region: Annotated[str, Field(description="The sales region.")],
        warehouse: Injected[Any],
    ) -> float:
        rows = warehouse.execute(
            "SELECT sum(revenue) AS total FROM sales WHERE region = ?", [region]
        ).fetchall()
        return float(rows[0][0])

    agent = Commons(
        client,
        {"warehouse": data_source(sales=frame())},
        semantic_layer=semantic_layer(region_revenue),
    )
    result = call_tool(
        agent, "call_measure", name="region_revenue", arguments='{"region": "EMEA"}'
    )

    assert "800" in result


def test_an_injected_argument_matching_no_source_fails_at_construction(
    client: Chat, source: Any
) -> None:
    @measure(description="Count orders.")
    def order_count(warehouse: Injected[Any]) -> int:
        return 0

    with pytest.raises(ValueError, match="order_count"):
        Commons(client, {"finance": source}, semantic_layer=semantic_layer(order_count))


def test_a_lone_unnamed_source_has_no_name_to_inject_by(
    client: Chat, source: Any
) -> None:
    @measure(description="Count orders.")
    def order_count(sales: Injected[Any]) -> int:
        return 0

    with pytest.raises(ValueError, match="no named data sources"):
        Commons(client, source, semantic_layer=semantic_layer(order_count))


# ---- prewarming -----------------------------------------------------------


def test_prewarm_builds_the_context_store_before_the_first_search(
    client: Chat, source: Any, tmp_path: Path
) -> None:
    notes = tmp_path / "notes.md"
    notes.write_text("# Revenue\n\nRevenue means booked revenue.", encoding="utf-8")
    agent = Commons(client, source, context_layer=context_layer(files=[notes]))
    layer = agent._context_layer
    assert layer is not None
    assert layer._store_cache is None

    agent.prewarm()

    assert layer._store_cache is not None
    assert "booked" in layer.search("revenue")[0]


def test_prewarm_without_a_context_layer_is_a_no_op(client: Chat, source: Any) -> None:
    Commons(client, source).prewarm()


def test_prewarm_reads_a_boards_pins(client: Chat, tmp_path: Path) -> None:
    pins = pytest.importorskip("pins")
    board = pins.board_folder(str(tmp_path))
    board.pin_write(frame(), "sales-pin", type="csv")
    agent = Commons(client, data_source(board, tables={"sales": "sales-pin"}))
    source = agent._sources["data"]
    assert source.pending is not None and source.pending.pins

    agent.prewarm()

    assert not source.pending.pins


def test_prewarm_propagates_a_failure(client: Chat, tmp_path: Path) -> None:
    pins = pytest.importorskip("pins")
    board = pins.board_folder(str(tmp_path))
    board.pin_write({"not": "a frame"}, "sales-pin", type="json")
    agent = Commons(client, data_source(board, tables={"sales": "sales-pin"}))

    # A cold cache should fail a deploy rather than warn and continue.
    with pytest.raises(TypeError, match="not a data frame"):
        agent.prewarm()


# ---- the model the prompt was built for -----------------------------------


def test_the_agent_asks_the_clients_own_provider(client: Chat, source: Any) -> None:
    agent = Commons(client, source)

    # The provider carries the model, so taking it is how the agent ends up
    # talking to what the caller chose.
    assert agent._client.provider is client.provider
    assert isinstance(agent._client.provider, ScriptedProvider)


def test_an_agent_says_how_many_sources_it_has(client: Chat, source: Any) -> None:
    assert repr(Commons(client, source)) == "A commons agent over 1 data source."
    assert (
        repr(Commons(scripted_chat(), {"a": source, "b": data_source(other=frame())}))
        == "A commons agent over 2 data sources."
    )


def test_the_scripted_provider_answers_offline(client: Chat, source: Any) -> None:
    agent = Commons(scripted_chat([text("Two orders.")]), source)

    assert str(agent.chat("How many orders?", echo="none")) == "Two orders."

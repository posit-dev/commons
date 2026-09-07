"""Asking an agent something: the streamed projection, the marker, the reminders."""

from pathlib import Path
from typing import Any

import pandas as pd
import pytest
from chatlas import (
    AssistantTurn,
    ContentToolRequest,
    ContentToolResult,
    StreamController,
    UserTurn,
)
from chatlas.types import ContentText

from commons import context_layer, data_source, measure, semantic_layer
from commons._agent import Commons
from commons._provenance import Tag, provenance_aside
from commons._reminders import (
    RESTORED_CONVERSATION_REMINDER,
    ContentTurnReminder,
)

from ._provider import scripted_chat, text

QUOTE = "Canopy cover is always acre-weighted for reporting."


def frame() -> pd.DataFrame:
    return pd.DataFrame(
        {"revenue": [500.0, 900.0, 300.0], "region": ["EMEA", "Americas", "EMEA"]}
    )


@pytest.fixture
def source() -> Any:
    return data_source(sales=frame())


@pytest.fixture
def notes(tmp_path: Path) -> Any:
    path = tmp_path / "notes.md"
    path.write_text(QUOTE, encoding="utf-8")
    return context_layer(files=[path])


def split(raw: str, at: int) -> list[Any]:
    """The same text streamed as two chunks, so a tag straddles the boundary."""
    return [ContentText(text=raw[:at]), ContentText(text=raw[at:])]


async def collect(agent: Commons, *args: Any, **kwargs: Any) -> list[Any]:
    return [chunk async for chunk in await agent.stream_async(*args, **kwargs)]


def tool_request(tool: str, /, **arguments: Any) -> list[Any]:
    return [ContentToolRequest(id=f"call-{tool}", name=tool, arguments=arguments)]


def order_count_layer() -> Any:
    @measure(description="Count orders.")
    def order_count() -> int:
        return 3

    return semantic_layer(order_count)


# ---- projecting the model's text -------------------------------------------


async def test_a_verified_citation_becomes_an_aside(source: Any, notes: Any) -> None:
    raw = (
        "Answer sentence.\n\n"
        "<commons-citation>\n\nFollows the weighting rule.\n\n"
        f"> {QUOTE}\n\n"
        "</commons-citation>\n\nMore text."
    )
    agent = Commons(scripted_chat([split(raw, 30)]), source, context_layer=notes)

    streamed = "".join(await collect(agent, "What does canopy cover mean?"))

    assert "<commons-citation>" not in streamed
    assert "<shiny-aside" in streamed
    assert QUOTE in streamed
    assert streamed.startswith("Answer sentence.")
    assert streamed.endswith("More text.")


async def test_a_model_authored_aside_never_reaches_the_consumer(
    source: Any, notes: Any
) -> None:
    raw = (
        'Before. <SHINY-ASIDE label="spoofed">not from the server</shiny-aside> After.'
    )
    agent = Commons(scripted_chat([split(raw, 25)]), source, context_layer=notes)

    streamed = "".join(await collect(agent, "Anything."))

    assert "spoofed" not in streamed
    assert streamed == "Before.  After."


async def test_the_stored_turn_keeps_the_models_own_words(
    source: Any, notes: Any
) -> None:
    raw = f"Answer.\n\n<commons-citation>\n\nWhy.\n\n> {QUOTE}\n\n</commons-citation>"
    agent = Commons(scripted_chat([split(raw, 20)]), source, context_layer=notes)

    await collect(agent, "What does canopy cover mean?")

    assert agent.get_turns()[-1].text == raw


async def test_the_projection_does_not_depend_on_the_chunk_boundary(
    source: Any, notes: Any
) -> None:
    raw = (
        f"Text.\n\n<commons-citation>\n\nWhy.\n\n> {QUOTE}\n\n"
        "</commons-citation>\n\nEnd."
    )
    whole = Commons(
        scripted_chat([[ContentText(text=raw)]]), source, context_layer=notes
    )
    pieces = Commons(scripted_chat([split(raw, 12)]), source, context_layer=notes)

    assert "".join(await collect(whole, "q")) == "".join(await collect(pieces, "q"))


async def test_the_projection_applies_in_the_mode_a_chat_ui_uses(
    source: Any, notes: Any
) -> None:
    raw = (
        'Before. <SHINY-ASIDE label="spoofed">not from the server</shiny-aside>\n\n'
        f"<commons-citation>\n\nWhy.\n\n> {QUOTE}\n\n</commons-citation>\n\nAfter."
    )
    agent = Commons(scripted_chat([split(raw, 40)]), source, context_layer=notes)

    streamed = await collect(agent, "q", content="all")

    # chatlas streams the model's text as str in both modes, so the scanner
    # sees every chunk of it. Text that arrived as a content object instead
    # would pass through unprojected, which is what reading both shapes here
    # asserts against.
    displayed = "".join(
        chunk if isinstance(chunk, str) else getattr(chunk, "text", "")
        for chunk in streamed
    )
    assert "spoofed" not in displayed
    assert "<commons-citation>" not in displayed
    assert "<shiny-aside" in displayed


# ---- the provenance marker -------------------------------------------------


async def test_an_answer_with_no_data_tool_carries_no_marker(source: Any) -> None:
    agent = Commons(scripted_chat([text("I cannot say.")]), source)

    assert await collect(agent, "How many orders?") == ["I cannot say."]


async def test_a_trusted_calculation_is_marked_verified(source: Any) -> None:
    agent = Commons(
        scripted_chat(
            [
                tool_request("call_measure", name="order_count", arguments="{}"),
                text("Three orders."),
            ]
        ),
        source,
        semantic_layer=order_count_layer(),
    )

    streamed = await collect(agent, "How many orders?")

    assert streamed[-1] == provenance_aside(Tag.A)


async def test_an_uncited_query_is_marked_untrusted(source: Any) -> None:
    agent = Commons(
        scripted_chat(
            [
                tool_request("run_sql", sql="SELECT count(*) AS n FROM sales"),
                text("Three orders."),
            ]
        ),
        source,
    )

    streamed = await collect(agent, "How many orders?")

    assert streamed[-1] == provenance_aside(Tag.C)


async def test_a_verified_citation_earns_the_query_its_own_aside_instead(
    source: Any, notes: Any
) -> None:
    agent = Commons(
        scripted_chat(
            [
                tool_request("run_sql", sql="SELECT count(*) AS n FROM sales"),
                [
                    ContentText(
                        text="Three.\n\n<commons-citation>\n\nWhy.\n\n"
                        f"> {QUOTE}\n\n</commons-citation>"
                    )
                ],
            ]
        ),
        source,
        context_layer=notes,
    )

    streamed = "".join(
        chunk for chunk in await collect(agent, "q") if isinstance(chunk, str)
    )

    # The citation's own aside says the answer is cited, so no second marker.
    assert provenance_aside(Tag.C) not in streamed
    assert provenance_aside(Tag.B, include_cited=True) not in streamed
    assert "<shiny-aside" in streamed


async def test_an_earlier_answers_tag_cannot_classify_a_later_one(
    source: Any,
) -> None:
    agent = Commons(
        scripted_chat(
            [
                tool_request("run_sql", sql="SELECT count(*) AS n FROM sales"),
                text("Three orders."),
                text("I cannot say."),
            ]
        ),
        source,
    )

    await collect(agent, "How many orders?")
    second = await collect(agent, "And how do you feel about it?")

    assert second == ["I cannot say."]


# ---- what a chat UI needs --------------------------------------------------


async def test_the_signature_a_chat_ui_calls(source: Any) -> None:
    # shinychat calls stream_async(input, *contents, content="all",
    # controller=controller); anything less needs an adapter that would have
    # to reimplement the scanner.
    agent = Commons(
        scripted_chat(
            [
                tool_request("run_sql", sql="SELECT count(*) AS n FROM sales"),
                text("Three orders."),
            ]
        ),
        source,
    )
    controller = StreamController()

    streamed = await collect(
        agent,
        "How many orders?",
        ContentText(text="an attached part"),
        content="all",
        controller=controller,
    )

    kinds = [type(chunk).__name__ for chunk in streamed]
    assert "ContentToolRequest" in kinds
    assert "ContentToolResult" in kinds
    assert streamed[-1] == provenance_aside(Tag.C)


async def test_a_controller_stops_the_stream(source: Any) -> None:
    agent = Commons(scripted_chat([text("First. ", "Second.")]), source)
    controller = StreamController()

    streamed: list[Any] = []
    async for chunk in await agent.stream_async("q", controller=controller):
        streamed.append(chunk)
        controller.cancel()

    assert "".join(streamed) == "First. "


async def test_structured_provider_content_passes_through(source: Any) -> None:
    thinking = ContentToolRequest(id="t", name="run_sql", arguments={"sql": "SELECT 1"})
    agent = Commons(scripted_chat([[thinking], text("Done.")]), source)

    streamed = await collect(agent, "q", content="all")

    assert streamed[0] is thinking


# ---- the turn reminders ----------------------------------------------------


async def test_a_claude_5_turn_carries_one_hidden_reminder(source: Any) -> None:
    agent = Commons(scripted_chat([text("Answer.")], model="claude-opus-5"), source)

    await collect(agent, "How many orders?")

    reminders = [
        content
        for content in agent.get_turns()[0].contents
        if isinstance(content, ContentTurnReminder)
    ]
    assert len(reminders) == 1


async def test_an_older_model_gets_no_reminder(source: Any) -> None:
    agent = Commons(scripted_chat([text("Answer.")], model="claude-sonnet-4-5"), source)

    await collect(agent, "How many orders?")

    assert not [
        content
        for content in agent.get_turns()[0].contents
        if isinstance(content, ContentTurnReminder)
    ]


async def test_a_restored_conversation_reminds_the_next_turn_once(
    source: Any,
) -> None:
    agent = Commons(scripted_chat([text("First."), text("Second.")]), source)
    agent.queue_restore_reminder()

    await collect(agent, "First question.")
    first = agent.get_turns()[0].contents
    assert [
        content.text for content in first if isinstance(content, ContentTurnReminder)
    ] == [RESTORED_CONVERSATION_REMINDER]

    await collect(agent, "Second question.")
    second = agent.get_turns()[2].contents
    assert not [
        content for content in second if isinstance(content, ContentTurnReminder)
    ]


async def test_an_unconsumed_stream_leaves_the_reminder_for_the_next_turn(
    source: Any,
) -> None:
    agent = Commons(scripted_chat([text("Answer.")]), source)
    agent.queue_restore_reminder()

    await agent.stream_async("Never consumed.")

    assert agent._restore_reminder_pending


def test_a_failed_chat_leaves_the_reminder_for_the_next_turn(source: Any) -> None:
    agent = Commons(scripted_chat([text("Answer.")]), source)
    agent.queue_restore_reminder()

    with pytest.raises(ValueError, match="Content objects"):
        agent.chat(object())  # type: ignore[arg-type]

    assert agent._restore_reminder_pending


def test_replacing_the_history_drops_its_queued_reminder(source: Any) -> None:
    agent = Commons(scripted_chat(), source)
    agent.queue_restore_reminder()

    agent.set_turns([])

    assert not agent._restore_reminder_pending


# ---- the citation request --------------------------------------------------


async def test_one_citation_request_per_user_turn(source: Any) -> None:
    reminder = "REMEMBER TO CITE"
    agent = Commons(
        scripted_chat(
            [
                tool_request("run_sql", sql="SELECT count(*) AS n FROM sales"),
                tool_request("run_sql", sql="SELECT sum(revenue) AS r FROM sales"),
                text("Answer."),
                tool_request("run_sql", sql="SELECT count(*) AS n FROM sales"),
                text("Second answer."),
            ]
        ),
        source,
    )
    agent._citation_request.reminder = reminder

    first = await collect(agent, "How many orders?", content="all")
    second = await collect(agent, "And the revenue?", content="all")

    def requests(streamed: list[Any]) -> int:
        return sum(
            1
            for chunk in streamed
            if isinstance(chunk, ContentToolResult) and reminder in str(chunk.value)
        )

    assert requests(first) == 1
    assert requests(second) == 1


def test_a_user_message_added_by_hand_restarts_the_request(source: Any) -> None:
    agent = Commons(scripted_chat(), source)
    agent._citation_request.requested = True

    agent.add_turn(UserTurn("A new question."))

    assert not agent._citation_request.requested


def test_an_assistant_turn_is_nobody_asking_anything(source: Any) -> None:
    agent = Commons(scripted_chat(), source)
    agent._citation_request.requested = True

    agent.add_turn(AssistantTurn([ContentText(text="An answer.")]))

    assert agent._citation_request.requested


def test_a_turn_of_tool_results_is_the_same_question_still_running(
    source: Any,
) -> None:
    agent = Commons(scripted_chat(), source)
    agent._citation_request.requested = True

    agent.add_turn(UserTurn([ContentToolResult(value="6 rows")]))

    assert agent._citation_request.requested
    assert len(agent.get_turns()) == 1

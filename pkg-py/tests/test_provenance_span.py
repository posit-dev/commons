"""The span that records an answer's provenance tag and citation decisions."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from chatlas import ContentToolRequest
from chatlas.types import ContentText

from commons import context_layer
from commons._citations import CitationDecision
from commons._tracing import (
    CANDIDATES_ATTRIBUTE,
    PROVENANCE_SPAN,
    TAG_ATTRIBUTE,
    citation_candidates_json,
)

from ._agents import agent_over, collect, logging_agent_over, sales
from ._provider import text
from ._shared import load_shared_fixture

PROVENANCE_TAGS = load_shared_fixture("provenance")["derive_provenance_tag"]["cases"]

TRACES = load_shared_fixture("traces")
PROVENANCE = TRACES["provenance"]
TURN = TRACES["conversation_turn"]

QUOTE = "Orders are one row per placed order."


def test_the_names_match_the_shared_contract() -> None:
    assert PROVENANCE_SPAN == PROVENANCE["span"]
    assert TAG_ATTRIBUTE == PROVENANCE["tag_attribute"]
    assert CANDIDATES_ATTRIBUTE == PROVENANCE["candidates_attribute"]


@pytest.mark.parametrize(
    "case", PROVENANCE["candidates_cases"], ids=lambda c: c["name"]
)
def test_decisions_serialize_to_the_shared_shape(case: Any) -> None:
    decisions = [CitationDecision(**decision) for decision in case["decisions"]]

    assert json.loads(citation_candidates_json(decisions)) == case["expected"]


def expected_tag(tags: list[str], verified: bool) -> str:
    (case,) = (
        c for c in PROVENANCE_TAGS if c["tags"] == tags and c["verified"] is verified
    )
    return case["expected"]


@pytest.fixture
def notes(tmp_path: Path) -> Any:
    path = tmp_path / "notes.md"
    path.write_text(QUOTE, encoding="utf-8")
    return context_layer(files=[path])


def run_sql() -> list[Any]:
    return [
        ContentToolRequest(
            id="call-run_sql",
            name="run_sql",
            arguments={"sql": "SELECT count(*) AS n FROM sales"},
        )
    ]


def cited(quote: str) -> list[Any]:
    return [
        ContentText(text=f"Three.\n\n<citation>\n\nWhy.\n\n> {quote}\n\n</citation>")
    ]


def candidates(provenance: Any) -> Any:
    return json.loads(provenance.attributes[CANDIDATES_ATTRIBUTE])


async def test_a_cited_answer_records_its_tag_and_decisions(
    logging_live: Any, notes: Any
) -> None:
    agent = logging_agent_over(sales(), [run_sql(), cited(QUOTE)], context_layer=notes)

    await collect(agent, "How many orders?")

    (turn,) = logging_live(TURN["span"])
    (provenance,) = logging_live(PROVENANCE["span"])
    assert provenance.parent.span_id == turn.context.span_id
    assert provenance.attributes[TAG_ATTRIBUTE] == expected_tag(["B"], True)
    assert [d["status"] for d in candidates(provenance)] == ["accepted"]


async def test_a_rejected_citation_is_recorded_with_an_untrusted_tag(
    logging_live: Any, notes: Any
) -> None:
    agent = logging_agent_over(
        sales(), [run_sql(), cited("Orders are perfect.")], context_layer=notes
    )

    await collect(agent, "How many orders?")

    (provenance,) = logging_live(PROVENANCE["span"])
    assert provenance.attributes[TAG_ATTRIBUTE] == expected_tag(["B"], False)
    assert candidates(provenance) == [
        {"quote": "Orders are perfect.", "status": "rejected"}
    ]


async def test_an_answer_with_no_tag_still_records_its_decisions(
    logging_live: Any,
) -> None:
    agent = logging_agent_over(sales(), [text("hello")])

    await collect(agent, "hello")

    (provenance,) = logging_live(PROVENANCE["span"])
    assert TAG_ATTRIBUTE not in provenance.attributes
    assert provenance.attributes[CANDIDATES_ATTRIBUTE] == "[]"


async def test_an_agent_that_does_not_log_records_no_provenance(
    logging_live: Any,
) -> None:
    await collect(agent_over(sales(), [text("hello")]), "hello")

    assert logging_live(PROVENANCE["span"]) == []


async def test_an_abandoned_stream_records_no_provenance(logging_live: Any) -> None:
    agent = logging_agent_over(
        sales(), [[ContentText(text="a"), ContentText(text="b")]]
    )

    stream = await agent.stream_async("hello")
    await anext(stream)
    await stream.aclose()

    assert logging_live(PROVENANCE["span"]) == []


async def test_a_failure_to_record_does_not_cost_the_answer(
    logging_live: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    def refuse(*args: object, **kwargs: object) -> None:
        raise RuntimeError("exporter gone")

    monkeypatch.setattr("commons._agent.record_provenance_span", refuse)
    agent = logging_agent_over(sales(), [text("hello")])

    chunks = await collect(agent, "hello")

    assert "".join(c for c in chunks if isinstance(c, str)) == "hello"

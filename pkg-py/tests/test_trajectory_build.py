"""Tests for rebuilding conversations from recorded spans.

The cases live in ``tests/shared/trajectories/build.json``, and the R suite
runs the same cases, so a case belongs in the fixture rather than here. This
module adds only what the fixture cannot pin.
"""

import warnings
from datetime import UTC, datetime
from typing import Any

import pytest
from chatlas import Turn

from commons._citations import CitationDecision
from commons._provenance import Tag
from commons._trajectory._build import (
    Exchange,
    Trajectory,
    build_trajectories,
)
from commons._trajectory._otlp import parse_otlp_lines
from tests._trajectories import (
    BUILD,
    BUILD_MEMBERS,
    assert_trajectories,
    cases,
    fixture_line,
    run_case,
)


def test_the_build_members_have_cases() -> None:
    for member in BUILD_MEMBERS:
        assert BUILD[member]["cases"], member


@pytest.mark.parametrize(("member", "case"), cases(BUILD_MEMBERS))
def test_spans_build_as_the_shared_fixture_pins(
    member: dict[str, Any], case: dict[str, Any]
) -> None:
    trajectories, notices = run_case(member, case)
    assert notices == ([] if case.get("notice") is None else [case["notice"]])
    assert_trajectories(trajectories, case["trajectories"])


def test_a_trajectory_has_the_public_types() -> None:
    (case,) = [c for c in BUILD["last_active"]["cases"] if c["name"].startswith("each")]
    trajectories, _ = run_case(BUILD["last_active"], case)
    trajectory = trajectories["t100"]
    assert isinstance(trajectory, Trajectory)
    assert trajectory.last_active == datetime(1970, 1, 1, 0, 1, 41, tzinfo=UTC)
    assert trajectory.last_active.tzinfo is UTC
    assert all(isinstance(turn, Turn) for turn in trajectory.turns)
    assert all(isinstance(e, Exchange) for e in trajectory.exchanges)


def _recorded(attributes: dict[str, Any]) -> Trajectory:
    """The conversation of one turn span, with these attributes, and its call."""
    spans = [
        {
            "trace": "t1",
            "span": "turn",
            "name": "commons_conversation_turn",
            "attributes": attributes,
        },
        {
            "trace": "t1",
            "span": "chat",
            "parent": "turn",
            "chat": True,
            "conversation": "conv-a",
            "input": [{"role": "user", "parts": [{"type": "text", "content": "Q1"}]}],
            "output": [
                {"role": "assistant", "parts": [{"type": "text", "content": "A1"}]}
            ],
        },
    ]
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        return build_trajectories(parse_otlp_lines([fixture_line(spans)]))["conv-a"]


def test_a_record_reads_as_a_tag_and_citation_decisions() -> None:
    accepted = {
        "quote": "Canopy cover is measured in June.",
        "status": "accepted",
        "label": "documentation",
        "kind": "prose",
    }
    trajectory = _recorded(
        {"commons.provenance.tag": "B", "commons.citation.candidates": [accepted]}
    )
    assert trajectory.exchanges[0].tag is Tag.B
    assert trajectory.exchanges[0].decisions == [
        CitationDecision(
            quote="Canopy cover is measured in June.",
            status="accepted",
            label="documentation",
            kind="prose",
        )
    ]


def test_a_decision_that_does_not_validate_is_dropped() -> None:
    candidates = [
        {"quote": "Q", "status": "accepted"},
        {"quote": "Q", "status": "unknown"},
        "text",
        {"quote": 3, "status": "rejected"},
        {"quote": "Q", "status": "accepted", "label": 3, "kind": "prose"},
        {"quote": "Kept.", "status": "rejected"},
    ]
    trajectory = _recorded({"commons.citation.candidates": candidates})
    assert trajectory.exchanges[0].decisions == [
        CitationDecision(quote="Kept.", status="rejected")
    ]


def test_an_unknown_tag_reads_as_none() -> None:
    trajectory = _recorded({"commons.provenance.tag": "Z"})
    assert trajectory.exchanges[0].tag is None


def test_exchanges_split_the_turns_at_each_question() -> None:
    """Each answer's record sits beside the turns it answers, and the system
    prompt, which answers nothing, is in no exchange."""

    def text(role: str, content: str) -> dict[str, Any]:
        return {"role": role, "parts": [{"type": "text", "content": content}]}

    spans = [
        {
            "trace": "t1",
            "span": "chat",
            "chat": True,
            "conversation": "conv-a",
            "system": [{"type": "text", "content": "Be brief."}],
            "input": [text("user", "Q1"), text("assistant", "A1"), text("user", "Q2")],
            "output": [text("assistant", "A2")],
        }
    ]
    trajectory = build_trajectories(parse_otlp_lines([fixture_line(spans)]))["conv-a"]
    assert [[t.text for t in e.turns] for e in trajectory.exchanges] == [
        ["Q1", "A1"],
        ["Q2", "A2"],
    ]
    assert trajectory.exchanges[1].turns[-1] is trajectory.turns[-1]

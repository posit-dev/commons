"""The span that records an answer's provenance tag and citation decisions."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from chatlas import ContentToolRequest
from chatlas.types import ContentText

from commons import context_layer, data_source
from commons._citations import CitationDecision
from commons._tracing import (
    CANDIDATES_ATTRIBUTE,
    PROVENANCE_SPAN,
    TAG_ATTRIBUTE,
    TURN_SPAN,
    citation_candidates_json,
)

from ._agents import agent_over, collect, frame, logging_agent_over
from ._provider import text
from ._shared import load_shared_fixture

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

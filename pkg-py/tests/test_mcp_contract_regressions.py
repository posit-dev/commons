"""Regression checks for the Python remote MCP contract."""

from typing import Any

import pytest

from commons._mcp import RemoteSession, _validator
from commons._mcp_contract import ENVELOPE_SCHEMA
from commons._provenance import Tag, derive_provenance_tag

from ._shared import load_shared_fixture

CONTRACT: dict[str, Any] = load_shared_fixture("mcp-contract")
SUCCESS_SCHEMA: dict[str, Any] = CONTRACT["success_schema"]


def _session_for(envelope: dict[str, Any]) -> RemoteSession:
    metadata = envelope["commons"]
    session = RemoteSession.__new__(RemoteSession)
    session.revision = metadata["catalog_revision"]
    session.sources = set(metadata["sources"])
    session.resources = {evidence["uri"]: evidence for evidence in metadata["evidence"]}
    return session


def test_runtime_schema_matches_the_shared_contract() -> None:
    assert ENVELOPE_SCHEMA == SUCCESS_SCHEMA
    assert CONTRACT["examples"]
    validator = _validator(ENVELOPE_SCHEMA)

    for case in CONTRACT["examples"]:
        envelope = case["envelope"]
        validator.validate(envelope)
        metadata = envelope["commons"]
        _session_for(envelope)._validate_envelope(
            metadata["tool_id"],
            {"execution_kind": metadata["execution_kind"]},
            envelope,
        )


def test_invalid_examples_fail_the_runtime_envelope_guard() -> None:
    examples = CONTRACT["invalid_examples"]
    assert examples
    validator = _validator(SUCCESS_SCHEMA)

    for case in examples:
        envelope = case["envelope"]
        assert validator.is_valid(envelope) is case["schema_valid"]
        with pytest.raises(ValueError, match="Invalid commons provenance envelope"):
            _session_for(envelope)._validate_envelope(
                case["expected_tool"],
                {"execution_kind": case["expected_execution_kind"]},
                envelope,
            )


def test_verified_mixed_exchange_uses_both_provenance_tags() -> None:
    tags = {
        case["envelope"]["commons"]["tool_id"]: case["envelope"]["commons"][
            "provenance_tag"
        ]
        for case in CONTRACT["examples"]
    }
    case = next(case for case in CONTRACT["exchanges"] if "expected_input_tags" in case)
    received = [tags[tool] for tool in case["tools"]]

    assert received == case["expected_input_tags"]
    assert derive_provenance_tag(
        [Tag(tag) for tag in received], verified=case["verified"]
    ) is Tag(case["expected_tag"])

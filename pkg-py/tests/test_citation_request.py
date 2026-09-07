"""The citation-request tracker and the tag a tool result carries."""

from typing import Any

from chatlas import ContentToolResult, UserTurn
from chatlas.types import ContentText

from commons._citations import CitationRequest, tool_result, turn_has_user_message
from commons._prompt import read_prompt
from commons._provenance import Tag

from ._shared import load_shared_fixture


def _fixture_value(spec: dict[str, Any]) -> Any:
    if spec["kind"] == "text":
        return spec["text"]
    return [ContentText(text=part) for part in spec["parts"]]


def _value_shape(value: Any) -> dict[str, Any]:
    if isinstance(value, str):
        return {"kind": "text", "text": value}
    return {"kind": "parts", "parts": [part.text for part in value]}


def test_tool_result_carries_its_provenance_tag():
    result = tool_result("6 rows", tag=Tag.B)

    assert isinstance(result, ContentToolResult)
    assert result.value == "6 rows"
    assert result.extra == {"commons_tag": Tag.B}


def test_shared_citation_request_cases():
    section = load_shared_fixture("citation-request")["requests"]
    assert section["cases"]

    for case in section["cases"]:
        tracker = CitationRequest(reminder=section["reminder"])
        for index, step in enumerate(case["steps"]):
            if step["action"] == "reset":
                tracker.reset()
                continue
            result = tracker.add_request(tool_result(_fixture_value(step["value"]), tag=Tag.B))
            assert _value_shape(result.value) == step["expected"], (
                f"{case['name']} step {index}"
            )


def test_a_value_that_is_neither_text_nor_parts_becomes_parts():
    frame = {"rows": 6}
    result = CitationRequest(reminder="REMINDER").add_request(
        tool_result(frame, tag=Tag.B)
    )

    assert result.value[0] == frame
    assert result.value[1].text == "REMINDER"


def test_shared_reset_cases():
    section = load_shared_fixture("citation-request")["resets"]
    assert section["cases"]

    for case in section["cases"]:
        contents = [
            ContentText(text="a question")
            if kind == "text"
            else tool_result("6 rows", tag=Tag.B)
            for kind in case["contents"]
        ]
        turn = UserTurn(contents)

        assert turn_has_user_message(turn) is case["resets"], case["name"]


def test_the_reminder_defaults_to_the_shipped_prompt_text():
    assert CitationRequest().reminder == read_prompt("citation-request.md")

"""Prompt rendering, including the cases shared with the R package."""

import re

import jinja2
import pandas as pd
import pytest

from commons import data_source
from commons._catalog._core import Manifest, Relation
from commons._data_dictionary import DataDictionary
from commons._data_source import DataSource, TableId
from commons._definitions._registry import build_registry
from commons._prompt import (
    EXECUTION_TOOL,
    check_instructions,
    citation_trust_exception,
    is_claude_5_model,
    prompt_date,
    read_instructions,
    read_prompt,
    render_system_prompt,
    system_prompt_data,
    system_prompt_template,
    tool_availability,
)

from ._shared import SHARED_DIR, load_shared_fixture

PROMPT_DATA = load_shared_fixture("prompt-data")


def _own_execution_tool(tool: str) -> str:
    """Resolve the fixtures' `$execution_tool` placeholder to this package's."""
    return EXECUTION_TOOL if tool == "$execution_tool" else tool

_PAD = re.compile(r"^pad:(\d+)$")


def _expand_pads(spec):
    """Grow the `pad:<n>` labels the fixture uses to exceed the index cap."""
    if isinstance(spec, dict):
        return {key: _expand_pads(value) for key, value in spec.items()}
    if isinstance(spec, list):
        return [_expand_pads(item) for item in spec]
    if isinstance(spec, str):
        padded = _PAD.match(spec)
        return "x" * int(padded.group(1)) if padded else spec
    return spec


def _manifest(catalog) -> Manifest:
    labels = [
        f"{catalog['label_prefix']}{index}"
        for index in range(1, catalog["objects"] + 1)
    ]
    relations = {label: Relation(id=TableId(table=label)) for label in labels}
    manifest = Manifest.build(relations, namespace_selected=True)
    assert manifest.searchable == catalog["searchable"]
    return manifest


def _hydrate(spec) -> DataSource:
    dictionary = spec.get("dictionary")
    source = data_source(
        dictionary=None
        if dictionary is None
        else DataDictionary.model_validate(_expand_pads(dictionary)),
        **{name: pd.DataFrame({"n": [1]}) for name in spec["tables"]},
    )
    if spec.get("catalog") is not None:
        source.manifest = _manifest(spec["catalog"])
    return source


def test_shared_render_cases():
    fixture = load_shared_fixture("prompt-render")
    cases = fixture["render"]["cases"]
    assert cases

    template = system_prompt_template()
    for case in cases:
        expected = (
            (SHARED_DIR / case["expected"]).read_text(encoding="utf-8").rstrip("\n")
        )
        assert render_system_prompt(template, case["data"]) == expected, case["name"]


def test_shared_tool_data_cases():
    cases = load_shared_fixture("prompt-render")["tool_data"]["cases"]
    assert cases

    for case in cases:
        tools = [_own_execution_tool(tool) for tool in case["tools"]]
        data: dict[str, object] = dict(tool_availability(tools))
        data["citation_trust_exception"] = citation_trust_exception(tools)
        got = {key: data[key] for key in case["expected"]}
        assert got == case["expected"], case["name"]


def test_shared_template_render_cases():
    cases = load_shared_fixture("prompt-render")["template_render"]["cases"]
    assert cases

    for case in cases:
        got = render_system_prompt(case["template"], case["data"])
        assert got == case["expected"], case["name"]


def test_shared_unsupported_templates():
    cases = load_shared_fixture("prompt-render")["unsupported"]["cases"]
    assert cases

    for case in cases:
        with pytest.raises(ValueError, match="Unsupported prompt template syntax"):
            render_system_prompt(case["template"], case["data"])


def test_shared_malformed_templates():
    cases = load_shared_fixture("prompt-render")["malformed"]["cases"]
    assert cases

    for case in cases:
        with pytest.raises((ValueError, TypeError, jinja2.TemplateSyntaxError)):
            render_system_prompt(case["template"], case["data"])


def test_shared_rejected_data():
    cases = load_shared_fixture("prompt-render")["rejected_data"]["cases"]
    assert cases

    for case in cases:
        with pytest.raises((TypeError, ValueError)):
            render_system_prompt(case["template"], case["data"])


def test_conditional_sections():
    template = (
        "<!-- source-only note -->\n"
        "{% if enabled %}\n"
        "{% if nested %}\nEnabled\nNested\n{% else %}\nEnabled\nNot nested\n{% endif %}\n"
        "{% else %}\nDisabled\n{% endif %}"
    )

    assert render_system_prompt(template, {"enabled": True, "nested": False}) == (
        "Enabled\nNot nested"
    )
    assert (
        render_system_prompt(template, {"enabled": False, "nested": True}) == "Disabled"
    )
    assert (
        render_system_prompt("{% if not on %}\nOff\n{% endif %}", {"on": False})
        == "Off"
    )


def test_values_are_not_rendered_again():
    template = (
        "Tables:\n{{ tables }}\nUse `{{ definition_token }}`. "
        "Write a literal {% raw %}`{{name}}`{% endraw %} token."
    )
    data = {
        "tables": "- sales\\daily\n- orders {{raw}}",
        "definition_token": "{{name}}",
    }

    assert render_system_prompt(template, data) == (
        "Tables:\n- sales\\daily\n- orders {{raw}}\nUse `{{name}}`. "
        "Write a literal `{{name}}` token."
    )


def test_template_data_is_validated():
    with pytest.raises(ValueError, match="has no value"):
        render_system_prompt("{% if unknown %}\nx\n{% endif %}", {})
    with pytest.raises(TypeError, match="must be True or False"):
        render_system_prompt("{% if tables %}\nx\n{% endif %}", {"tables": "a"})
    with pytest.raises(TypeError, match="must be a string"):
        render_system_prompt("{{ tables }}", {"tables": ["a", "b"]})


def test_claude_5_model_ids_are_recognized_across_providers():
    assert is_claude_5_model("claude-sonnet-5")
    assert is_claude_5_model("anthropic/claude-opus-5")
    assert is_claude_5_model("us.anthropic.claude-fable-5")
    assert is_claude_5_model("databricks-claude-sonnet-5")
    assert not is_claude_5_model("claude-sonnet-4-5")
    assert not is_claude_5_model("gpt-5.4")
    assert not is_claude_5_model(None)


def test_missing_instruction_paths_are_recognized(tmp_path):
    with pytest.raises(FileNotFoundError):
        check_instructions("missing-instructions.Rmd")
    with pytest.raises(FileNotFoundError):
        check_instructions("missing-instructions.template")
    with pytest.raises(FileNotFoundError):
        check_instructions("missing-dir/instructions")
    check_instructions("Be concise.")
    check_instructions("Line one.\nLine two.")
    check_instructions(None)

    path = tmp_path / "instructions.md"
    path.write_text("Prefer weekly grain.\n", encoding="utf-8")
    assert read_instructions(str(path)) == "Prefer weekly grain."
    assert read_instructions("Be concise.") == "Be concise."


def test_citation_request_text_names_the_dialect():
    reminder = read_prompt("citation-request.md")

    assert "<commons-citation>" in reminder
    assert "\n" not in reminder


@pytest.mark.parametrize("case", PROMPT_DATA["cases"], ids=lambda case: case["name"])
def test_shared_prompt_data_cases(case):
    sources = {spec["name"]: _hydrate(spec) for spec in case["sources"]}
    data = system_prompt_data(
        sources,
        build_registry(sources),
        instructions=case.get("instructions"),
        tools=[_own_execution_tool(tool) for tool in case.get("tools", [])],
        model=case.get("model"),
    )

    assert list(data) == PROMPT_DATA["fields"]
    assert (
        data["execution_tool"]
        == PROMPT_DATA["substitutions"]["python"]["execution_tool"]
    )
    assert {key: data[key] for key in case["expect"]} == case["expect"]


def test_shared_prompt_data_cases_are_not_empty():
    assert PROMPT_DATA["cases"]


def test_prompt_data_renders_the_packaged_template():
    source = data_source(orders=pd.DataFrame({"n": [1]}))
    sources = {"sales_db": source}
    data = system_prompt_data(sources, build_registry(sources), tools=["run_sql"])

    prompt = render_system_prompt(system_prompt_template(), data)

    assert data["date"] == prompt_date()
    assert "{{" not in prompt.replace("`{{name}}`", "")


def test_prompt_data_reads_tool_names_from_any_iterable():
    source = data_source(orders=pd.DataFrame({"n": [1]}))
    sources = {"sales_db": source}
    # Both the trust exception and the per-tool flags read `tools`, so a
    # one-shot iterator has to survive being read twice.
    data = system_prompt_data(
        sources, build_registry(sources), tools=iter(["call_metrics"])
    )

    assert data["has_call_metrics"]
    assert data["citation_trust_exception"].endswith("`call_metrics`")

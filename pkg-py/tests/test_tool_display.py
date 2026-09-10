"""How a tool result asks to be shown, read back through shinychat's own reader.

`extra["display"]` is a plain dictionary rather than a `ToolResultDisplay`,
so that core can describe a result's presentation without importing
shinychat. These tests read it back through `get_tool_result_display()`,
which is the code that consumes it, rather than asserting on the dictionary.
"""

import pytest
from chatlas import ContentToolRequest, ContentToolResult

from commons._citations import tool_result
from commons._provenance import TAG_EXTRA_KEY, Tag

pytest.importorskip("shinychat")

from shinychat._chat_normalize_chatlas import (  # noqa: E402
    get_tool_result_display,
)
from shinychat.types import ToolResultDisplay  # noqa: E402


def shown(result: ContentToolResult) -> ToolResultDisplay:
    """The display shinychat builds for `result`, as it would when rendering."""
    request = ContentToolRequest(id="1", name="run_sql", arguments={})
    return get_tool_result_display(result, request)


def test_a_result_with_no_title_asks_for_nothing() -> None:
    assert shown(tool_result("6 rows")).title is None


def test_a_title_reaches_the_reader() -> None:
    result = tool_result("chunks", title="Searched context")
    assert shown(result).title == "Searched context"


def test_a_tag_stays_out_of_the_title() -> None:
    """The tag is provenance the reader classifies by, not a caption.

    R has a `show_tag` argument that would append "SQL query (B)", but every
    call site passes `show_tag = FALSE`, so no R title carries one either.
    """
    result = tool_result("6 rows", title="Retrieved data", tag=Tag.B)
    assert shown(result).title == "Retrieved data"


def test_a_display_does_not_cost_a_result_its_tag() -> None:
    result = tool_result("41", title="Ran a trusted calculation", tag=Tag.A)
    assert result.extra[TAG_EXTRA_KEY] is Tag.A


def test_markdown_is_what_the_reader_sees_in_the_card() -> None:
    result = tool_result("6 rows", title="Retrieved data", markdown="| a |\n|---|")
    assert shown(result).markdown == "| a |\n|---|"
